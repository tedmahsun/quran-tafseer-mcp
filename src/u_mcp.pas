unit u_mcp;

{$mode objfpc}{$H+}

interface

const
  // Server identity
  SERVER_NAME       = 'quranref';
  SERVER_VERSION    = '0.1.0';
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

implementation

uses
  SysUtils, fpjson, u_log, u_jsonrpc;

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

  ToolsCap := TJSONObject.Create;  // empty for M0

  Capabilities := TJSONObject.Create;
  Capabilities.Add('tools', ToolsCap);

  ResObj := TJSONObject.Create;
  ResObj.Add('protocolVersion', PROTOCOL_VERSION);
  ResObj.Add('serverInfo', ServerInfo);
  ResObj.Add('capabilities', Capabilities);

  Result := BuildJsonRpcResult(AReq, ResObj);
end;

function HandleToolsList(const AReq: TJsonRpcRequest): TJSONObject;
var
  ResObj: TJSONObject;
begin
  ResObj := TJSONObject.Create;
  ResObj.Add('tools', TJSONArray.Create);
  Result := BuildJsonRpcResult(AReq, ResObj);
end;

function HandleToolsCall(const AReq: TJsonRpcRequest): TJSONObject;
var
  ToolName: String;
begin
  ToolName := '';
  if (AReq.Params <> nil) and (AReq.Params is TJSONObject) then
    ToolName := TJSONObject(AReq.Params).Get('name', '');

  LogWarn('tools/call for unknown tool: ' + ToolName);
  Result := BuildJsonRpcError(AReq, JSONRPC_INVALID_PARAMS,
    'Unknown tool: ' + ToolName);
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
