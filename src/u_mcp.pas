unit u_mcp;

{$mode objfpc}{$H+}

interface

uses
  fpjson;

const
  // Server identity
  SERVER_NAME       = 'quran-tafseer-mcp';
  SERVER_VERSION    = '1.0.0';
  PROTOCOL_VERSION  = '2024-11-05';

  // Application-specific error codes
  ERR_SETUP_INCOMPLETE      = -32001;
  ERR_CORPUS_NOT_FOUND      = -32002;
  ERR_VERSE_OUT_OF_RANGE    = -32003;
  ERR_RANGE_TOO_LARGE       = -32004;
  ERR_INDEX_MISSING         = -32005;
  ERR_CROSS_SURAH_RANGE     = -32006;
  ERR_DOWNLOAD_FAILED       = -32007;
  ERR_CHECKSUM_MISMATCH     = -32008;
  ERR_CATALOG_ID_UNKNOWN    = -32009;
  ERR_DATA_ROOT_NOT_WRITABLE = -32010;

type
  TMcpServerState = (msAwaitingInit, msInitialized, msShutdown);

/// Run the main MCP read-dispatch-respond loop until EOF.
procedure RunMcpLoop;

// ============================================================================
// SHARED SCHEMA HELPERS (used by u_mcp and u_tools_setup)
// ============================================================================

function MakeStringProp(const ADesc: String): TJSONObject;
function MakeIntProp(const ADesc: String): TJSONObject;
function MakeBoolProp(const ADesc: String; ADefault: Boolean): TJSONObject;

implementation

uses
  SysUtils, u_log, u_jsonrpc, u_tools_quran, u_tools_setup,
  u_corpus_store;

var
  ServerState: TMcpServerState = msAwaitingInit;

function HandleInitialize(const AReq: TJsonRpcRequest): TJSONObject;
var
  ResObj, ServerInfo, Capabilities, ToolsCap: TJSONObject;
begin
  ServerState := msInitialized;
  LogInfo('MCP initialize received');

  ServerInfo := TJSONObject.Create;
  ServerInfo.Add('name', SERVER_NAME);
  ServerInfo.Add('version', SERVER_VERSION);

  ToolsCap := TJSONObject.Create;

  Capabilities := TJSONObject.Create;
  Capabilities.Add('tools', ToolsCap);

  ResObj := TJSONObject.Create;
  ResObj.Add('protocolVersion', PROTOCOL_VERSION);
  ResObj.Add('serverInfo', ServerInfo);
  ResObj.Add('capabilities', Capabilities);

  Result := BuildJsonRpcResult(AReq, ResObj);
end;

// ============================================================================
// Tool schema builders
// ============================================================================

function MakeStringProp(const ADesc: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'string');
  Result.Add('description', ADesc);
end;

function MakeIntProp(const ADesc: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'integer');
  Result.Add('description', ADesc);
end;

function MakeBoolProp(const ADesc: String; ADefault: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'boolean');
  Result.Add('description', ADesc);
  Result.Add('default', ADefault);
end;

function MakeFormatProp: TJSONObject;
var
  EnumArr: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'string');
  Result.Add('description',
    'Output format. "structured" returns JSON (default). ' +
    '"terminal" returns preformatted text optimized for terminal display.');
  EnumArr := TJSONArray.Create;
  EnumArr.Add('structured');
  EnumArr.Add('terminal');
  Result.Add('enum', EnumArr);
  Result.Add('default', 'structured');
end;

function BuildToolSchema_ListTranslations: TJSONObject;
var
  Schema, Props: TJSONObject;
begin
  Props := TJSONObject.Create;
  Props.Add('lang', MakeStringProp('Language filter (e.g. "en", "ar"). Optional.'));
  Props.Add('format', MakeFormatProp);

  Schema := TJSONObject.Create;
  Schema.Add('type', 'object');
  Schema.Add('properties', Props);

  Result := TJSONObject.Create;
  Result.Add('name', 'quran.list_translations');
  Result.Add('description',
    'List all installed translation and Arabic corpora. ' +
    'Returns corpus IDs, titles, and metadata.');
  Result.Add('inputSchema', Schema);
end;

function BuildToolSchema_GetAyah: TJSONObject;
var
  Schema, Props, TransProp: TJSONObject;
  Required, TransOneOf: TJSONArray;
  TransArr, TransStr: TJSONObject;
begin
  Props := TJSONObject.Create;
  Props.Add('surah', MakeIntProp('Surah number (1-114).'));
  Props.Add('ayah', MakeIntProp('Ayah number within the surah.'));

  // translations: string "all" or array of corpus IDs
  TransOneOf := TJSONArray.Create;
  TransStr := TJSONObject.Create;
  TransStr.Add('type', 'string');
  TransStr.Add('enum', TJSONArray.Create(['all']));
  TransOneOf.Add(TransStr);
  TransArr := TJSONObject.Create;
  TransArr.Add('type', 'array');
  TransArr.Add('items', MakeStringProp('Corpus ID'));
  TransOneOf.Add(TransArr);
  TransProp := TJSONObject.Create;
  TransProp.Add('description',
    'Which translations to include. "all" for all installed, ' +
    'or an array of corpus IDs. Default: "all".');
  TransProp.Add('oneOf', TransOneOf);
  Props.Add('translations', TransProp);

  Props.Add('include_arabic', MakeBoolProp(
    'Whether to include Arabic text. Default: true.', True));
  Props.Add('arabic_id', MakeStringProp(
    'Arabic corpus ID to use. Default: first available.'));
  Props.Add('format', MakeFormatProp);

  Required := TJSONArray.Create;
  Required.Add('surah');
  Required.Add('ayah');

  Schema := TJSONObject.Create;
  Schema.Add('type', 'object');
  Schema.Add('properties', Props);
  Schema.Add('required', Required);

  Result := TJSONObject.Create;
  Result.Add('name', 'quran.get_ayah');
  Result.Add('description',
    'Fetch Arabic text and translations for a single Quran verse. ' +
    'Returns the verse text from each requested corpus with citations.');
  Result.Add('inputSchema', Schema);
end;

function BuildToolSchema_ResolveRef: TJSONObject;
var
  Schema, Props: TJSONObject;
  Required: TJSONArray;
begin
  Props := TJSONObject.Create;
  Props.Add('ref', MakeStringProp(
    'A Quran reference to resolve. Accepts formats like ' +
    '"2:255", "Q 2:255", "Al-Baqarah 255", or a surah name.'));
  Props.Add('format', MakeFormatProp);

  Required := TJSONArray.Create;
  Required.Add('ref');

  Schema := TJSONObject.Create;
  Schema.Add('type', 'object');
  Schema.Add('properties', Props);
  Schema.Add('required', Required);

  Result := TJSONObject.Create;
  Result.Add('name', 'quran.resolve_ref');
  Result.Add('description',
    'Normalize a Quran reference to canonical (surah, ayah) form. ' +
    'Accepts numeric ("2:255"), prefixed ("Q 2:255"), or named ' +
    '("Al-Baqarah 255") references.');
  Result.Add('inputSchema', Schema);
end;

function BuildToolSchema_GetRange: TJSONObject;
var
  Schema, Props, TransProp: TJSONObject;
  Required, TransOneOf: TJSONArray;
  TransArr, TransStr: TJSONObject;
begin
  Props := TJSONObject.Create;
  Props.Add('surah', MakeIntProp('Surah number (1-114).'));
  Props.Add('start_ayah', MakeIntProp('First ayah number in the range.'));
  Props.Add('end_ayah', MakeIntProp('Last ayah number in the range (inclusive).'));

  // translations: string "all" or array of corpus IDs
  TransOneOf := TJSONArray.Create;
  TransStr := TJSONObject.Create;
  TransStr.Add('type', 'string');
  TransStr.Add('enum', TJSONArray.Create(['all']));
  TransOneOf.Add(TransStr);
  TransArr := TJSONObject.Create;
  TransArr.Add('type', 'array');
  TransArr.Add('items', MakeStringProp('Corpus ID'));
  TransOneOf.Add(TransArr);
  TransProp := TJSONObject.Create;
  TransProp.Add('description',
    'Which translations to include. "all" for all installed, ' +
    'or an array of corpus IDs. Default: "all".');
  TransProp.Add('oneOf', TransOneOf);
  Props.Add('translations', TransProp);

  Props.Add('include_arabic', MakeBoolProp(
    'Whether to include Arabic text. Default: true.', True));
  Props.Add('arabic_id', MakeStringProp(
    'Arabic corpus ID to use. Default: first available.'));
  Props.Add('format', MakeFormatProp);

  Required := TJSONArray.Create;
  Required.Add('surah');
  Required.Add('start_ayah');
  Required.Add('end_ayah');

  Schema := TJSONObject.Create;
  Schema.Add('type', 'object');
  Schema.Add('properties', Props);
  Schema.Add('required', Required);

  Result := TJSONObject.Create;
  Result.Add('name', 'quran.get_range');
  Result.Add('description',
    'Fetch Arabic text and translations for a range of verses within a single surah. ' +
    'Returns verse texts with citations. Max verses per call depends on translation count ' +
    '(1-2: 25, 3-6: 15, 7+: 10). Truncated responses include a continuation hint.');
  Result.Add('inputSchema', Schema);
end;

function BuildToolSchema_Search: TJSONObject;
var
  Schema, Props, TransProp: TJSONObject;
  Required, TransOneOf: TJSONArray;
  TransArr, TransStr: TJSONObject;
begin
  Props := TJSONObject.Create;
  Props.Add('query', MakeStringProp('Search query string.'));

  // translations: array of corpus IDs (optional)
  TransOneOf := TJSONArray.Create;
  TransStr := TJSONObject.Create;
  TransStr.Add('type', 'string');
  TransStr.Add('enum', TJSONArray.Create(['all']));
  TransOneOf.Add(TransStr);
  TransArr := TJSONObject.Create;
  TransArr.Add('type', 'array');
  TransArr.Add('items', MakeStringProp('Corpus ID'));
  TransOneOf.Add(TransArr);
  TransProp := TJSONObject.Create;
  TransProp.Add('description',
    'Which translation corpora to search. "all" for all indexed translations, ' +
    'or an array of corpus IDs. Default: "all".');
  TransProp.Add('oneOf', TransOneOf);
  Props.Add('translations', TransProp);

  Props.Add('limit', MakeIntProp(
    'Maximum number of results to return (1-50). Default: 20.'));
  Props.Add('format', MakeFormatProp);

  Required := TJSONArray.Create;
  Required.Add('query');

  Schema := TJSONObject.Create;
  Schema.Add('type', 'object');
  Schema.Add('properties', Props);
  Schema.Add('required', Required);

  Result := TJSONObject.Create;
  Result.Add('name', 'quran.search');
  Result.Add('description',
    'Full-text search across installed translation corpora. ' +
    'Returns matching verse references with snippets and relevance scores. ' +
    'Use quran.get_ayah or quran.get_range to view full verse texts.');
  Result.Add('inputSchema', Schema);
end;

function BuildToolSchema_Diff: TJSONObject;
var
  Schema, Props, TransProp: TJSONObject;
  Required: TJSONArray;
begin
  Props := TJSONObject.Create;
  Props.Add('surah', MakeIntProp('Surah number (1-114).'));
  Props.Add('ayah', MakeIntProp('Ayah number within the surah.'));

  TransProp := TJSONObject.Create;
  TransProp.Add('type', 'array');
  TransProp.Add('items', MakeStringProp('Corpus ID'));
  TransProp.Add('minItems', 2);
  TransProp.Add('description',
    'Array of corpus IDs to compare (minimum 2). ' +
    'The first corpus is the base; subsequent ones are diffed against it.');
  Props.Add('translations', TransProp);
  Props.Add('format', MakeFormatProp);

  Required := TJSONArray.Create;
  Required.Add('surah');
  Required.Add('ayah');
  Required.Add('translations');

  Schema := TJSONObject.Create;
  Schema.Add('type', 'object');
  Schema.Add('properties', Props);
  Schema.Add('required', Required);

  Result := TJSONObject.Create;
  Result.Add('name', 'quran.diff');
  Result.Add('description',
    'Word-level diff between translations for a single verse. ' +
    'First translation in the array is the base; each subsequent one ' +
    'is compared against it. Returns token-level equal/delete/insert ops ' +
    'and similarity statistics.');
  Result.Add('inputSchema', Schema);
end;

// ============================================================================
// MCP handlers
// ============================================================================

function HandleToolsList(const AReq: TJsonRpcRequest): TJSONObject;
var
  ResObj: TJSONObject;
  ToolsArr: TJSONArray;
begin
  ToolsArr := TJSONArray.Create;
  ToolsArr.Add(BuildToolSchema_ListTranslations);
  ToolsArr.Add(BuildToolSchema_GetAyah);
  ToolsArr.Add(BuildToolSchema_GetRange);
  ToolsArr.Add(BuildToolSchema_ResolveRef);
  ToolsArr.Add(BuildToolSchema_Search);
  ToolsArr.Add(BuildToolSchema_Diff);
  ToolsArr.Add(BuildToolSchema_Setup);

  ResObj := TJSONObject.Create;
  ResObj.Add('tools', ToolsArr);
  Result := BuildJsonRpcResult(AReq, ResObj);
end;

function HandleToolsCall(const AReq: TJsonRpcRequest): TJSONObject;
var
  ToolName: String;
  ParamsObj, ArgsObj: TJSONObject;
begin
  ToolName := '';
  ArgsObj := nil;

  if (AReq.Params <> nil) and (AReq.Params is TJSONObject) then
  begin
    ParamsObj := TJSONObject(AReq.Params);
    ToolName := ParamsObj.Get('name', '');

    // Arguments are in the "arguments" field
    if ParamsObj.IndexOfName('arguments') >= 0 then
    begin
      if ParamsObj.Elements['arguments'] is TJSONObject then
        ArgsObj := TJSONObject(ParamsObj.Elements['arguments']);
    end;
  end;

  LogInfo('tools/call: ' + ToolName);

  // Setup-incomplete guard: if no corpora loaded, only quran.setup is allowed
  if (GetCorpusCount = 0) and (ToolName <> 'quran.setup') then
  begin
    Result := BuildToolError(AReq, ERR_SETUP_INCOMPLETE,
      'No corpora installed. Run quran.setup with action "install_bundled" first.');
    Exit;
  end;

  if ToolName = 'quran.list_translations' then
    Result := HandleListTranslations(AReq, ArgsObj)
  else if ToolName = 'quran.get_ayah' then
    Result := HandleGetAyah(AReq, ArgsObj)
  else if ToolName = 'quran.get_range' then
    Result := HandleGetRange(AReq, ArgsObj)
  else if ToolName = 'quran.resolve_ref' then
    Result := HandleResolveRef(AReq, ArgsObj)
  else if ToolName = 'quran.search' then
    Result := HandleSearch(AReq, ArgsObj)
  else if ToolName = 'quran.diff' then
    Result := HandleDiff(AReq, ArgsObj)
  else if ToolName = 'quran.setup' then
    Result := HandleSetup(AReq, ArgsObj)
  else
  begin
    LogWarn('tools/call for unknown tool: ' + ToolName);
    Result := BuildJsonRpcError(AReq, JSONRPC_INVALID_PARAMS,
      'Unknown tool: ' + ToolName);
  end;
end;

function HandlePing(const AReq: TJsonRpcRequest): TJSONObject;
begin
  Result := BuildJsonRpcResult(AReq, TJSONObject.Create);
end;

function McpDispatch(AObj: TJSONObject): TJSONObject;
var
  Req: TJsonRpcRequest;
begin
  Result := nil;
  Req := ParseJsonRpcRequest(AObj);

  // Validate: must have a method
  if Req.Method = '' then
  begin
    if Req.HasId then
      Result := BuildJsonRpcError(Req, JSONRPC_INVALID_REQUEST,
        'Missing method field')
    else
      LogWarn('Received message with no method and no id');
    Exit;
  end;

  LogDebug('dispatch: method=' + Req.Method);

  // Notifications (no id) — handle and return nil (no response)
  if Req.Method = 'notifications/initialized' then
  begin
    LogInfo('Client sent notifications/initialized');
    Exit;  // No response for notifications
  end;

  // If this is a notification (no id) for an unknown notification, just log and skip
  if not Req.HasId then
  begin
    LogDebug('Ignoring unknown notification: ' + Req.Method);
    Exit;
  end;

  // Pre-init guard: only initialize and ping are allowed before init
  if (ServerState = msAwaitingInit) and
     (Req.Method <> 'initialize') and (Req.Method <> 'ping') then
  begin
    Result := BuildJsonRpcError(Req, JSONRPC_INVALID_REQUEST,
      'Server not initialized. Send initialize first.');
    Exit;
  end;

  // Route to handlers
  if Req.Method = 'initialize' then
    Result := HandleInitialize(Req)
  else if Req.Method = 'tools/list' then
    Result := HandleToolsList(Req)
  else if Req.Method = 'tools/call' then
    Result := HandleToolsCall(Req)
  else if Req.Method = 'ping' then
    Result := HandlePing(Req)
  else
  begin
    LogWarn('Method not found: ' + Req.Method);
    Result := BuildJsonRpcError(Req, JSONRPC_METHOD_NOT_FOUND,
      'Method not found: ' + Req.Method);
  end;
end;

procedure RunMcpLoop;
var
  Msg, Response: TJSONObject;
  ReadStatus: TReadResult;
begin
  LogInfo(SERVER_NAME + ' v' + SERVER_VERSION + ' starting MCP loop');

  repeat
    Msg := nil;
    Response := nil;
    try
      Msg := ReadJsonRpcMessage(ReadStatus);
      if ReadStatus = rrEof then
      begin
        LogInfo('EOF on stdin — shutting down');
        Break;
      end;
      if ReadStatus = rrParseError then
      begin
        Response := BuildJsonRpcErrorNoId(JSONRPC_PARSE_ERROR,
          'Parse error: invalid JSON');
        WriteJsonRpcMessage(Response);
        FreeAndNil(Response);
        Continue;
      end;

      Response := McpDispatch(Msg);
      if Response <> nil then
        WriteJsonRpcMessage(Response);
    except
      on E: Exception do
      begin
        LogError('Unhandled exception in MCP loop: ' + E.Message);
        // Try to send an internal error if we can
        try
          if Response = nil then
          begin
            Response := BuildJsonRpcErrorNoId(JSONRPC_INTERNAL_ERROR,
              'Internal error: ' + E.Message);
            WriteJsonRpcMessage(Response);
          end;
        except
          // Swallow — nothing more we can do
        end;
      end;
    end;
    FreeAndNil(Response);
    FreeAndNil(Msg);
  until False;

  ServerState := msShutdown;
  LogInfo('MCP loop ended');
end;

end.
