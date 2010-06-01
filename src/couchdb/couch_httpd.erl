% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_httpd).
-include("couch_db.hrl").

-export([start_link/0, stop/0, handle_request/6]).

-export([header_value/2,header_value/3,qs_value/2,qs_value/3,qs/1,path/1,absolute_uri/2,body_length/1]).
-export([verify_is_server_admin/1,unquote/1,quote/1,recv/2,recv_chunked/4,error_info/1]).
-export([make_fun_spec_strs/1, make_arity_1_fun/1]).
-export([parse_form/1,json_body/1,json_body_obj/1,body/1,doc_etag/1, make_etag/1, etag_respond/3]).
-export([primary_header_value/2,partition/1,serve_file/3,serve_file/4, server_header/0]).
-export([start_chunked_response/3,send_chunk/2,log_request/2]).
-export([start_response_length/4, send/2]).
-export([start_json_response/2, start_json_response/3, end_json_response/1]).
-export([send_response/4,send_method_not_allowed/2,send_error/4, send_redirect/2,send_chunked_error/2]).
-export([send_json/2,send_json/3,send_json/4,last_chunk/1,parse_multipart_request/3]).
-export([accepted_encodings/1,handle_request_int/5]).

start_link() ->
    % read config and register for configuration changes

    % just stop if one of the config settings change. couch_server_sup
    % will restart us and then we will pick up the new settings.

    BindAddress = couch_config:get("httpd", "bind_address", any),
    Port = couch_config:get("httpd", "port", "5984"),
    VirtualHosts = couch_config:get("vhosts"),

    DefaultSpec = "{couch_httpd_db, handle_request}",
    DefaultFun = make_arity_1_fun(
        couch_config:get("httpd", "default_handler", DefaultSpec)
    ),

    UrlHandlersList = lists:map(
        fun({UrlKey, SpecStr}) ->
            {?l2b(UrlKey), make_arity_1_fun(SpecStr)}
        end, couch_config:get("httpd_global_handlers")),

    DbUrlHandlersList = lists:map(
        fun({UrlKey, SpecStr}) ->
            {?l2b(UrlKey), make_arity_2_fun(SpecStr)}
        end, couch_config:get("httpd_db_handlers")),

    DesignUrlHandlersList = lists:map(
        fun({UrlKey, SpecStr}) ->
            {?l2b(UrlKey), make_arity_3_fun(SpecStr)}
        end, couch_config:get("httpd_design_handlers")),

    UrlHandlers = dict:from_list(UrlHandlersList),
    DbUrlHandlers = dict:from_list(DbUrlHandlersList),
    DesignUrlHandlers = dict:from_list(DesignUrlHandlersList),
    Loop = fun(Req)->
        apply(?MODULE, handle_request, [
            Req, DefaultFun, UrlHandlers, DbUrlHandlers, DesignUrlHandlers,
                VirtualHosts
        ])
    end,

    % and off we go

    {ok, Pid} = case mochiweb_http:start([
        {loop, Loop},
        {name, ?MODULE},
        {ip, BindAddress},
        {port, Port}
    ]) of
    {ok, MochiPid} -> {ok, MochiPid};
    {error, Reason} ->
        io:format("Failure to start Mochiweb: ~s~n",[Reason]),
        throw({error, Reason})
    end,

    ok = couch_config:register(
        fun("httpd", "bind_address") ->
            ?MODULE:stop();
        ("httpd", "port") ->
            ?MODULE:stop();
        ("httpd", "default_handler") ->
            ?MODULE:stop();
        ("httpd_global_handlers", _) ->
            ?MODULE:stop();
        ("httpd_db_handlers", _) ->
            ?MODULE:stop();
        ("vhosts", _) ->
            ?MODULE:stop()
        end, Pid),

    {ok, Pid}.

% SpecStr is a string like "{my_module, my_fun}"
%  or "{my_module, my_fun, <<"my_arg">>}"
make_arity_1_fun(SpecStr) ->
    case couch_util:parse_term(SpecStr) of
    {ok, {Mod, Fun, SpecArg}} ->
        fun(Arg) -> Mod:Fun(Arg, SpecArg) end;
    {ok, {Mod, Fun}} ->
        fun(Arg) -> Mod:Fun(Arg) end
    end.

make_arity_2_fun(SpecStr) ->
    case couch_util:parse_term(SpecStr) of
    {ok, {Mod, Fun, SpecArg}} ->
        fun(Arg1, Arg2) -> Mod:Fun(Arg1, Arg2, SpecArg) end;
    {ok, {Mod, Fun}} ->
        fun(Arg1, Arg2) -> Mod:Fun(Arg1, Arg2) end
    end.

make_arity_3_fun(SpecStr) ->
    case couch_util:parse_term(SpecStr) of
    {ok, {Mod, Fun, SpecArg}} ->
        fun(Arg1, Arg2, Arg3) -> Mod:Fun(Arg1, Arg2, Arg3, SpecArg) end;
    {ok, {Mod, Fun}} ->
        fun(Arg1, Arg2, Arg3) -> Mod:Fun(Arg1, Arg2, Arg3) end
    end.

% SpecStr is "{my_module, my_fun}, {my_module2, my_fun2}"
make_fun_spec_strs(SpecStr) ->
    re:split(SpecStr, "(?<=})\\s*,\\s*(?={)", [{return, list}]).

stop() ->
    mochiweb_http:stop(?MODULE).

%%

% if there's a vhost definition that matches the request, redirect internally
redirect_to_vhost(MochiReq, DefaultFun,
    UrlHandlers, DbUrlHandlers, DesignUrlHandlers, VhostTarget) ->

    Path = MochiReq:get(raw_path),
    Target = VhostTarget ++ Path,
    ?LOG_DEBUG("Vhost Target: '~p'~n", [Target]),
    % build a new mochiweb request
    MochiReq1 = mochiweb_request:new(MochiReq:get(socket),
                                      MochiReq:get(method),
                                      Target,
                                      MochiReq:get(version),
                                      MochiReq:get(headers)),
    % cleanup, It force mochiweb to reparse raw uri.
    MochiReq1:cleanup(),

    handle_request_int(MochiReq1, DefaultFun,
        UrlHandlers, DbUrlHandlers, DesignUrlHandlers).

handle_request(MochiReq, DefaultFun,
    UrlHandlers, DbUrlHandlers, DesignUrlHandlers, VirtualHosts) ->

    % grab Host from Req
    Vhost = MochiReq:get_header_value("Host"),

    % find Vhost in config
    case proplists:get_value(Vhost, VirtualHosts) of
        undefined -> % business as usual
            handle_request_int(MochiReq, DefaultFun,
                    UrlHandlers, DbUrlHandlers, DesignUrlHandlers);
        VhostTarget ->
            redirect_to_vhost(MochiReq, DefaultFun,
                UrlHandlers, DbUrlHandlers, DesignUrlHandlers, VhostTarget)
    end.


handle_request_int(MochiReq, DefaultFun,
            UrlHandlers, DbUrlHandlers, DesignUrlHandlers) ->
    Begin = now(),
    AuthenticationSrcs = make_fun_spec_strs(
            couch_config:get("httpd", "authentication_handlers")),
    % for the path, use the raw path with the query string and fragment
    % removed, but URL quoting left intact
    RawUri = MochiReq:get(raw_path),
    {"/" ++ Path, _, _} = mochiweb_util:urlsplit_path(RawUri),

    HandlerKey =
    case mochiweb_util:partition(Path, "/") of
    {"", "", ""} ->
        <<"/">>; % Special case the root url handler
    {FirstPart, _, _} ->
        list_to_binary(FirstPart)
    end,
    ?LOG_DEBUG("~p ~s ~p~nHeaders: ~p", [
        MochiReq:get(method),
        RawUri,
        MochiReq:get(version),
        mochiweb_headers:to_list(MochiReq:get(headers))
    ]),
    
    Method1 =
    case MochiReq:get(method) of
        % already an atom
        Meth when is_atom(Meth) -> Meth;

        % Non standard HTTP verbs aren't atoms (COPY, MOVE etc) so convert when
        % possible (if any module references the atom, then it's existing).
        Meth -> couch_util:to_existing_atom(Meth)
    end,
    increment_method_stats(Method1),
    % alias HEAD to GET as mochiweb takes care of stripping the body
    Method = case Method1 of
        'HEAD' -> 'GET';
        Other -> Other
    end,

    HttpReq = #httpd{
        mochi_req = MochiReq,
        peer = MochiReq:get(peer),
        method = Method,
        path_parts = [list_to_binary(couch_httpd:unquote(Part))
                || Part <- string:tokens(Path, "/")],
        db_url_handlers = DbUrlHandlers,
        design_url_handlers = DesignUrlHandlers,
        default_fun = DefaultFun,
        url_handlers = UrlHandlers
    },

    HandlerFun = couch_util:dict_find(HandlerKey, UrlHandlers, DefaultFun),

    {ok, Resp} =
    try
        case authenticate_request(HttpReq, AuthenticationSrcs) of
        #httpd{} = Req ->
            HandlerFun(Req);
        Response ->
            Response
        end
    catch
        throw:{http_head_abort, Resp0} ->
            {ok, Resp0};
        throw:{invalid_json, S} ->
            ?LOG_ERROR("attempted upload of invalid JSON ~s", [S]),
            send_error(HttpReq, {bad_request, "invalid UTF-8 JSON"});
        throw:unacceptable_encoding ->
            ?LOG_ERROR("unsupported encoding method for the response", []),
            send_error(HttpReq, {not_acceptable, "unsupported encoding"});
        throw:bad_accept_encoding_value ->
            ?LOG_ERROR("received invalid Accept-Encoding header", []),
            send_error(HttpReq, bad_request);
        exit:normal ->
            exit(normal);
        throw:Error ->
            ?LOG_DEBUG("Minor error in HTTP request: ~p",[Error]),
            ?LOG_DEBUG("Stacktrace: ~p",[erlang:get_stacktrace()]),
            send_error(HttpReq, Error);
        error:badarg ->
            ?LOG_ERROR("Badarg error in HTTP request",[]),
            ?LOG_INFO("Stacktrace: ~p",[erlang:get_stacktrace()]),
            send_error(HttpReq, badarg);
        error:function_clause ->
            ?LOG_ERROR("function_clause error in HTTP request",[]),
            ?LOG_INFO("Stacktrace: ~p",[erlang:get_stacktrace()]),
            send_error(HttpReq, function_clause);
        Tag:Error ->
            ?LOG_ERROR("Uncaught error in HTTP request: ~p",[{Tag, Error}]),
            ?LOG_INFO("Stacktrace: ~p",[erlang:get_stacktrace()]),
            send_error(HttpReq, Error)
    end,
    RequestTime = round(timer:now_diff(now(), Begin)/1000),
    couch_stats_collector:record({couchdb, request_time}, RequestTime),
    couch_stats_collector:increment({httpd, requests}),
    {ok, Resp}.

% Try authentication handlers in order until one sets a user_ctx
% the auth funs also have the option of returning a response
% move this to couch_httpd_auth?
authenticate_request(#httpd{user_ctx=#user_ctx{}} = Req, _AuthSrcs) ->
    Req;
authenticate_request(#httpd{} = Req, []) ->
    case couch_config:get("couch_httpd_auth", "require_valid_user", "false") of
    "true" ->
        throw({unauthorized, <<"Authentication required.">>});
    "false" ->
        Req#httpd{user_ctx=#user_ctx{}}
    end;
authenticate_request(#httpd{} = Req, [AuthSrc|Rest]) ->
    AuthFun = make_arity_1_fun(AuthSrc),
    R = case AuthFun(Req) of
        #httpd{user_ctx=#user_ctx{}=UserCtx}=Req2 ->
            Req2#httpd{user_ctx=UserCtx#user_ctx{handler=?l2b(AuthSrc)}};
        Else -> Else
    end,
    authenticate_request(R, Rest);
authenticate_request(Response, _AuthSrcs) ->
    Response.

increment_method_stats(Method) ->
    couch_stats_collector:increment({httpd_request_methods, Method}).


% Utilities

partition(Path) ->
    mochiweb_util:partition(Path, "/").

header_value(#httpd{mochi_req=MochiReq}, Key) ->
    MochiReq:get_header_value(Key).

header_value(#httpd{mochi_req=MochiReq}, Key, Default) ->
    case MochiReq:get_header_value(Key) of
    undefined -> Default;
    Value -> Value
    end.

primary_header_value(#httpd{mochi_req=MochiReq}, Key) ->
    MochiReq:get_primary_header_value(Key).

accepted_encodings(#httpd{mochi_req=MochiReq}) ->
    case MochiReq:accepted_encodings(["gzip", "identity"]) of
    bad_accept_encoding_value ->
        throw(bad_accept_encoding_value);
    [] ->
        throw(unacceptable_encoding);
    EncList ->
        EncList
    end.

serve_file(Req, RelativePath, DocumentRoot) ->
    serve_file(Req, RelativePath, DocumentRoot, []).

serve_file(#httpd{mochi_req=MochiReq}=Req, RelativePath, DocumentRoot, ExtraHeaders) ->
    {ok, MochiReq:serve_file(RelativePath, DocumentRoot,
        server_header() ++ couch_httpd_auth:cookie_auth_header(Req, []) ++ ExtraHeaders)}.

qs_value(Req, Key) ->
    qs_value(Req, Key, undefined).

qs_value(Req, Key, Default) ->
    proplists:get_value(Key, qs(Req), Default).

qs(#httpd{mochi_req=MochiReq}) ->
    MochiReq:parse_qs().

path(#httpd{mochi_req=MochiReq}) ->
    MochiReq:get(path).

absolute_uri(#httpd{mochi_req=MochiReq}, Path) ->
    XHost = couch_config:get("httpd", "x_forwarded_host", "X-Forwarded-Host"),
    Host = case MochiReq:get_header_value(XHost) of
        undefined ->
            case MochiReq:get_header_value("Host") of
                undefined ->    
                    {ok, {Address, Port}} = inet:sockname(MochiReq:get(socket)),
                    inet_parse:ntoa(Address) ++ ":" ++ integer_to_list(Port);
                Value1 ->
                    Value1
            end;
        Value -> Value
    end,
    XSsl = couch_config:get("httpd", "x_forwarded_ssl", "X-Forwarded-Ssl"),
    Scheme = case MochiReq:get_header_value(XSsl) of
        "on" -> "https";
        _ ->
            XProto = couch_config:get("httpd", "x_forwarded_proto", "X-Forwarded-Proto"),
            case MochiReq:get_header_value(XProto) of
                % Restrict to "https" and "http" schemes only
                "https" -> "https";
                _ -> "http"
            end
    end,
    Scheme ++ "://" ++ Host ++ Path.

unquote(UrlEncodedString) ->
    mochiweb_util:unquote(UrlEncodedString).

quote(UrlDecodedString) ->
    mochiweb_util:quote_plus(UrlDecodedString).

parse_form(#httpd{mochi_req=MochiReq}) ->
    mochiweb_multipart:parse_form(MochiReq).

recv(#httpd{mochi_req=MochiReq}, Len) ->
    MochiReq:recv(Len).

recv_chunked(#httpd{mochi_req=MochiReq}, MaxChunkSize, ChunkFun, InitState) ->
    % Fun is called once with each chunk
    % Fun({Length, Binary}, State)
    % called with Length == 0 on the last time.
    MochiReq:stream_body(MaxChunkSize, ChunkFun, InitState).
    
body_length(Req) ->
    case header_value(Req, "Transfer-Encoding") of
        undefined ->
            case header_value(Req, "Content-Length") of
                undefined -> undefined;
                Length -> list_to_integer(Length)
            end;
        "chunked" -> chunked;
        Unknown -> {unknown_transfer_encoding, Unknown}
    end.

body(#httpd{mochi_req=MochiReq, req_body=ReqBody}) ->
    case ReqBody of
        undefined ->
            % Maximum size of document PUT request body (4GB)
            MaxSize = list_to_integer(
                couch_config:get("couchdb", "max_document_size", "4294967296")),
            MochiReq:recv_body(MaxSize);
        _Else ->
            ReqBody
    end.

json_body(Httpd) ->
    ?JSON_DECODE(body(Httpd)).

json_body_obj(Httpd) ->
    case json_body(Httpd) of
        {Props} -> {Props};
        _Else ->
            throw({bad_request, "Request body must be a JSON object"})
    end.



doc_etag(#doc{revs={Start, [DiskRev|_]}}) ->
    "\"" ++ ?b2l(couch_doc:rev_to_str({Start, DiskRev})) ++ "\"".

make_etag(Term) ->
    <<SigInt:128/integer>> = erlang:md5(term_to_binary(Term)),
    list_to_binary("\"" ++ lists:flatten(io_lib:format("~.36B",[SigInt])) ++ "\"").

etag_match(Req, CurrentEtag) when is_binary(CurrentEtag) ->
    etag_match(Req, binary_to_list(CurrentEtag));

etag_match(Req, CurrentEtag) ->
    EtagsToMatch = string:tokens(
        couch_httpd:header_value(Req, "If-None-Match", ""), ", "),
    lists:member(CurrentEtag, EtagsToMatch).

etag_respond(Req, CurrentEtag, RespFun) ->
    case etag_match(Req, CurrentEtag) of
    true ->
        % the client has this in their cache.
        couch_httpd:send_response(Req, 304, [{"Etag", CurrentEtag}], <<>>);
    false ->
        % Run the function.
        RespFun()
    end.

verify_is_server_admin(#httpd{user_ctx=UserCtx}) ->
    verify_is_server_admin(UserCtx);
verify_is_server_admin(#user_ctx{roles=Roles}) ->
    case lists:member(<<"_admin">>, Roles) of
    true -> ok;
    false -> throw({unauthorized, <<"You are not a server admin.">>})
    end.

log_request(#httpd{mochi_req=MochiReq,peer=Peer,method=Method}, Code) ->
    ?LOG_INFO("~s - - ~p ~s ~B", [
        Peer,
        Method,
        MochiReq:get(raw_path),
        couch_util:to_integer(Code)
    ]).


start_response_length(#httpd{mochi_req=MochiReq}=Req, Code, Headers, Length) ->
    log_request(Req, Code),
    couch_stats_collector:increment({httpd_status_codes, Code}),
    Resp = MochiReq:start_response_length({Code, Headers ++ server_header() ++ couch_httpd_auth:cookie_auth_header(Req, Headers), Length}),
    case MochiReq:get(method) of
    'HEAD' -> throw({http_head_abort, Resp});
    _ -> ok
    end,
    {ok, Resp}.

send(Resp, Data) ->
    Resp:send(Data),
    {ok, Resp}.

no_resp_conn_header([]) ->
    true;
no_resp_conn_header([{Hdr, _}|Rest]) ->
    case string:to_lower(Hdr) of
        "connection" -> false;
        _ -> no_resp_conn_header(Rest)
    end.

http_1_0_keep_alive(Req, Headers) ->
    KeepOpen = Req:should_close() == false,
    IsHttp10 = Req:get(version) == {1, 0},
    NoRespHeader = no_resp_conn_header(Headers),
    case KeepOpen andalso IsHttp10 andalso NoRespHeader of
        true -> [{"Connection", "Keep-Alive"} | Headers];
        false -> Headers
    end.

start_chunked_response(#httpd{mochi_req=MochiReq}=Req, Code, Headers) ->
    log_request(Req, Code),
    couch_stats_collector:increment({httpd_status_codes, Code}),
    Headers2 = http_1_0_keep_alive(MochiReq, Headers),
    Resp = MochiReq:respond({Code, Headers2 ++ server_header() ++ couch_httpd_auth:cookie_auth_header(Req, Headers2), chunked}),
    case MochiReq:get(method) of
    'HEAD' -> throw({http_head_abort, Resp});
    _ -> ok
    end,
    {ok, Resp}.

send_chunk(Resp, Data) ->
    case iolist_size(Data) of
    0 -> ok; % do nothing
    _ -> Resp:write_chunk(Data)
    end,
    {ok, Resp}.

last_chunk(Resp) ->
    Resp:write_chunk([]),
    {ok, Resp}.

send_response(#httpd{mochi_req=MochiReq}=Req, Code, Headers, Body) ->
    log_request(Req, Code),
    couch_stats_collector:increment({httpd_status_codes, Code}),
    Headers2 = http_1_0_keep_alive(MochiReq, Headers),
    if Code >= 400 ->
        ?LOG_DEBUG("httpd ~p error response:~n ~s", [Code, Body]);
    true -> ok
    end,
    {ok, MochiReq:respond({Code, Headers2 ++ server_header() ++ couch_httpd_auth:cookie_auth_header(Req, Headers2), Body})}.

send_method_not_allowed(Req, Methods) ->
    send_error(Req, 405, [{"Allow", Methods}], <<"method_not_allowed">>, ?l2b("Only " ++ Methods ++ " allowed")).

send_json(Req, Value) ->
    send_json(Req, 200, Value).

send_json(Req, Code, Value) ->
    send_json(Req, Code, [], Value).

send_json(Req, Code, Headers, Value) ->
    DefaultHeaders = [
        {"Content-Type", negotiate_content_type(Req)},
        {"Cache-Control", "must-revalidate"}
    ],
    Body = list_to_binary(
        [start_jsonp(Req), ?JSON_ENCODE(Value), end_jsonp(), $\n]
    ),
    send_response(Req, Code, DefaultHeaders ++ Headers, Body).

start_json_response(Req, Code) ->
    start_json_response(Req, Code, []).

start_json_response(Req, Code, Headers) ->
    DefaultHeaders = [
        {"Content-Type", negotiate_content_type(Req)},
        {"Cache-Control", "must-revalidate"}
    ],
    start_jsonp(Req), % Validate before starting chunked.
    %start_chunked_response(Req, Code, DefaultHeaders ++ Headers).
    {ok, Resp} = start_chunked_response(Req, Code, DefaultHeaders ++ Headers),
    case start_jsonp(Req) of
        [] -> ok;
        Start -> send_chunk(Resp, Start)
    end,
    {ok, Resp}.

end_json_response(Resp) ->
    send_chunk(Resp, end_jsonp() ++ [$\n]),
    last_chunk(Resp).

start_jsonp(Req) ->
    case get(jsonp) of
        undefined -> put(jsonp, qs_value(Req, "callback", no_jsonp));
        _ -> ok
    end,
    case get(jsonp) of
        no_jsonp -> [];
        [] -> [];
        CallBack ->
            try
                % make sure jsonp is configured on (default off)
                case couch_config:get("httpd", "allow_jsonp", "false") of
                "true" -> 
                    validate_callback(CallBack),
                    CallBack ++ "(";
                _Else -> 
                    % this could throw an error message, but instead we just ignore the 
                    % jsonp parameter
                    % throw({bad_request, <<"JSONP must be configured before using.">>})
                    put(jsonp, no_jsonp),
                    []
                end
            catch
                Error ->
                    put(jsonp, no_jsonp),
                    throw(Error)
            end
    end.

end_jsonp() ->
    Resp = case get(jsonp) of
        no_jsonp -> [];
        [] -> [];
        _ -> ");"
    end,
    put(jsonp, undefined),
    Resp.

validate_callback(CallBack) when is_binary(CallBack) ->
    validate_callback(binary_to_list(CallBack));
validate_callback([]) ->
    ok;
validate_callback([Char | Rest]) ->
    case Char of
        _ when Char >= $a andalso Char =< $z -> ok;
        _ when Char >= $A andalso Char =< $Z -> ok;
        _ when Char >= $0 andalso Char =< $9 -> ok;
        _ when Char == $. -> ok;
        _ when Char == $_ -> ok;
        _ when Char == $[ -> ok;
        _ when Char == $] -> ok;
        _ ->
            throw({bad_request, invalid_callback})
    end,
    validate_callback(Rest).


error_info({Error, Reason}) when is_list(Reason) ->
    error_info({Error, ?l2b(Reason)});
error_info(bad_request) ->
    {400, <<"bad_request">>, <<>>};
error_info({bad_request, Reason}) ->
    {400, <<"bad_request">>, Reason};
error_info({query_parse_error, Reason}) ->
    {400, <<"query_parse_error">>, Reason};
% Prior art for md5 mismatch resulting in a 400 is from AWS S3
error_info(md5_mismatch) ->
    {400, <<"content_md5_mismatch">>, <<"Possible message corruption.">>};
error_info(not_found) ->
    {404, <<"not_found">>, <<"missing">>};
error_info({not_found, Reason}) ->
    {404, <<"not_found">>, Reason};
error_info({not_acceptable, Reason}) ->
    {406, <<"not_acceptable">>, Reason};
error_info(conflict) ->
    {409, <<"conflict">>, <<"Document update conflict.">>};
error_info({forbidden, Msg}) ->
    {403, <<"forbidden">>, Msg};
error_info({unauthorized, Msg}) ->
    {401, <<"unauthorized">>, Msg};
error_info(file_exists) ->
    {412, <<"file_exists">>, <<"The database could not be "
        "created, the file already exists.">>};
error_info({bad_ctype, Reason}) ->
    {415, <<"bad_content_type">>, Reason};
error_info({error, illegal_database_name}) ->
    {400, <<"illegal_database_name">>, <<"Only lowercase characters (a-z), "
        "digits (0-9), and any of the characters _, $, (, ), +, -, and / "
        "are allowed">>};
error_info({missing_stub, Reason}) ->
    {412, <<"missing_stub">>, Reason};
error_info({Error, Reason}) ->
    {500, couch_util:to_binary(Error), couch_util:to_binary(Reason)};
error_info(Error) ->
    {500, <<"unknown_error">>, couch_util:to_binary(Error)}.

send_error(_Req, {already_sent, Resp, _Error}) ->
    {ok, Resp};

send_error(#httpd{mochi_req=MochiReq}=Req, Error) ->
    {Code, ErrorStr, ReasonStr} = error_info(Error),
    Headers = if Code == 401 ->
        % this is where the basic auth popup is triggered
        case MochiReq:get_header_value("X-CouchDB-WWW-Authenticate") of
        undefined ->
            case couch_config:get("httpd", "WWW-Authenticate", nil) of
            nil ->
                [];
            Type ->
                [{"WWW-Authenticate", Type}]
            end;
        Type ->
            [{"WWW-Authenticate", Type}]
        end;
    true ->
        []
    end,
    send_error(Req, Code, Headers, ErrorStr, ReasonStr).

send_error(Req, Code, ErrorStr, ReasonStr) ->
    send_error(Req, Code, [], ErrorStr, ReasonStr).

send_error(Req, Code, Headers, ErrorStr, ReasonStr) ->
    send_json(Req, Code, Headers,
        {[{<<"error">>,  ErrorStr},
         {<<"reason">>, ReasonStr}]}).

% give the option for list functions to output html or other raw errors
send_chunked_error(Resp, {_Error, {[{<<"body">>, Reason}]}}) ->
    send_chunk(Resp, Reason),
    last_chunk(Resp);

send_chunked_error(Resp, Error) ->
    {Code, ErrorStr, ReasonStr} = error_info(Error),
    JsonError = {[{<<"code">>, Code},
        {<<"error">>,  ErrorStr},
        {<<"reason">>, ReasonStr}]},
    send_chunk(Resp, ?l2b([$\n,?JSON_ENCODE(JsonError),$\n])),
    last_chunk(Resp).

send_redirect(Req, Path) ->
     Headers = [{"Location", couch_httpd:absolute_uri(Req, Path)}],
     send_response(Req, 301, Headers, <<>>).

negotiate_content_type(#httpd{mochi_req=MochiReq}) ->
    %% Determine the appropriate Content-Type header for a JSON response
    %% depending on the Accept header in the request. A request that explicitly
    %% lists the correct JSON MIME type will get that type, otherwise the
    %% response will have the generic MIME type "text/plain"
    AcceptedTypes = case MochiReq:get_header_value("Accept") of
        undefined       -> [];
        AcceptHeader    -> string:tokens(AcceptHeader, ", ")
    end,
    case lists:member("application/json", AcceptedTypes) of
        true  -> "application/json";
        false -> "text/plain;charset=utf-8"
    end.

server_header() ->
    OTPVersion = "R" ++ integer_to_list(erlang:system_info(compat_rel)) ++ "B",
    [{"Server", "CouchDB/" ++ couch_server:get_version() ++
                " (Erlang OTP/" ++ OTPVersion ++ ")"}].


-record(mp, {boundary, buffer, data_fun, callback}).


parse_multipart_request(ContentType, DataFun, Callback) ->
    Boundary0 = iolist_to_binary(get_boundary(ContentType)),
    Boundary = <<"\r\n--", Boundary0/binary>>,
    Mp = #mp{boundary= Boundary,
            buffer= <<>>,
            data_fun=DataFun,
            callback=Callback},
    {Mp2, _NilCallback} = read_until(Mp, <<"--", Boundary0/binary>>, 
        fun(Next)-> nil_callback(Next) end),
    #mp{buffer=Buffer, data_fun=DataFun2, callback=Callback2} = 
            parse_part_header(Mp2),
    {Buffer, DataFun2, Callback2}.

nil_callback(_Data)->
    fun(Next) -> nil_callback(Next) end.

get_boundary(ContentType) ->
    {"multipart/" ++ _, Opts} = mochiweb_util:parse_header(ContentType),
    case proplists:get_value("boundary", Opts) of
        S when is_list(S) ->
            S
    end.



split_header(<<>>) ->
    [];
split_header(Line) ->
    {Name, [$: | Value]} = lists:splitwith(fun (C) -> C =/= $: end,
                                           binary_to_list(Line)),
    [{string:to_lower(string:strip(Name)),
     mochiweb_util:parse_header(Value)}].

read_until(#mp{data_fun=DataFun, buffer=Buffer}=Mp, Pattern, Callback) ->
    case find_in_binary(Pattern, Buffer) of
    not_found ->
        Callback2 = Callback(Buffer),
        {Buffer2, DataFun2} = DataFun(),
        Buffer3 = iolist_to_binary(Buffer2),
        read_until(Mp#mp{data_fun=DataFun2,buffer=Buffer3}, Pattern, Callback2);
    {partial, Skip} ->
        <<DataChunk:Skip/binary, Rest/binary>> = Buffer,
        Callback2 = Callback(DataChunk),
        {NewData, DataFun2} = DataFun(),
        read_until(Mp#mp{data_fun=DataFun2,
                buffer= iolist_to_binary([Rest | NewData])},
                Pattern, Callback2);
    {exact, Skip} ->
        PatternLen = size(Pattern),
        <<DataChunk:Skip/binary, _:PatternLen/binary, Rest/binary>> = Buffer,
        Callback2 = Callback(DataChunk),
        {Mp#mp{buffer= Rest}, Callback2}
    end.


parse_part_header(#mp{callback=UserCallBack}=Mp) ->
    {Mp2, AccCallback} = read_until(Mp, <<"\r\n\r\n">>,
            fun(Next) -> acc_callback(Next, []) end),
    HeaderData = AccCallback(get_data),
    
    Headers =
    lists:foldl(fun(Line, Acc) ->
            split_header(Line) ++ Acc
        end, [], re:split(HeaderData,<<"\r\n">>, [])),
    NextCallback = UserCallBack({headers, Headers}),
    parse_part_body(Mp2#mp{callback=NextCallback}).

parse_part_body(#mp{boundary=Prefix, callback=Callback}=Mp) ->
    {Mp2, WrappedCallback} = read_until(Mp, Prefix,
            fun(Data) -> body_callback_wrapper(Data, Callback) end),
    Callback2 = WrappedCallback(get_callback),
    Callback3 = Callback2(body_end),
    case check_for_last(Mp2#mp{callback=Callback3}) of
    {last, #mp{callback=Callback3}=Mp3} ->
        Mp3#mp{callback=Callback3(eof)};
    {more, Mp3} ->
        parse_part_header(Mp3)
    end.

acc_callback(get_data, Acc)->
    iolist_to_binary(lists:reverse(Acc));
acc_callback(Data, Acc)->
    fun(Next) -> acc_callback(Next, [Data | Acc]) end.

body_callback_wrapper(get_callback, Callback) ->
    Callback;
body_callback_wrapper(Data, Callback) ->
    Callback2 = Callback({body, Data}),
    fun(Next) -> body_callback_wrapper(Next, Callback2) end.


check_for_last(#mp{buffer=Buffer, data_fun=DataFun}=Mp) ->
    case Buffer of
    <<"--",_/binary>> -> {last, Mp};
    <<_, _, _/binary>> -> {more, Mp};
    _ -> % not long enough
        {Data, DataFun2} = DataFun(),
        check_for_last(Mp#mp{buffer= <<Buffer/binary, Data/binary>>,
                data_fun = DataFun2})
    end.

find_in_binary(B, Data) when size(B) > 0 ->
    case size(Data) - size(B) of
        Last when Last < 0 ->
            partial_find(B, Data, 0, size(Data));
        Last ->
            find_in_binary(B, size(B), Data, 0, Last)
    end.

find_in_binary(B, BS, D, N, Last) when N =< Last->
    case D of
        <<_:N/binary, B:BS/binary, _/binary>> ->
            {exact, N};
        _ ->
            find_in_binary(B, BS, D, 1 + N, Last)
    end;
find_in_binary(B, BS, D, N, Last) when N =:= 1 + Last ->
    partial_find(B, D, N, BS - 1).

partial_find(_B, _D, _N, 0) ->
    not_found;
partial_find(B, D, N, K) ->
    <<B1:K/binary, _/binary>> = B,
    case D of
        <<_Skip:N/binary, B1/binary>> ->
            {partial, N};
        _ ->
            partial_find(B, D, 1 + N, K - 1)
    end.

