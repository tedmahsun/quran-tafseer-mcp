unit u_jsonrpc;

{$mode objfpc}{$H+}

interface

uses
  fpjson;

const
  // Standard JSON-RPC error codes
  JSONRPC_PARSE_ERROR      = -32700;
  JSONRPC_INVALID_REQUEST  = -32600;
  JSONRPC_METHOD_NOT_FOUND = -32601;
  JSONRPC_INVALID_PARAMS   = -32602;
  JSONRPC_INTERNAL_ERROR   = -32603;

type
  TReadResult = (rrSuccess, rrEof, rrParseError);

  TJsonRpcRequest = record
    Method: String;
    Params: TJSONData;   // Borrowed reference — do not free; freed with owning TJSONObject
    HasId: Boolean;
    IdNum: Int64;
    IdStr: String;
    IsStringId: Boolean;
  end;

/// Read one newline-delimited JSON-RPC message from stdin.
/// Returns nil on EOF or parse error. Check AStatus for reason.
/// Caller must free the returned object.
function ReadJsonRpcMessage(out AStatus: TReadResult): TJSONObject;

/// Write a JSON-RPC message to stdout as newline-delimited JSON.
/// Does not free AObj.
procedure WriteJsonRpcMessage(AObj: TJSONObject);

/// Parse a JSON object into a structured request record.
function ParseJsonRpcRequest(AObj: TJSONObject): TJsonRpcRequest;

/// Build a JSON-RPC success response. Caller must free.
/// AResult is adopted (will be freed with the returned object).
function BuildJsonRpcResult(const AReq: TJsonRpcRequest; AResult: TJSONData): TJSONObject;

/// Build a JSON-RPC error response. Caller must free.
/// AData may be nil. If non-nil, it is adopted.
function BuildJsonRpcError(const AReq: TJsonRpcRequest;
  ACode: Integer; const AMessage: String; AData: TJSONData = nil): TJSONObject;

/// Build a JSON-RPC error response with no id (for parse errors). Caller must free.
function BuildJsonRpcErrorNoId(ACode: Integer; const AMessage: String): TJSONObject;

/// Initialize stdio for JSON-RPC transport.
/// Must be called once at startup before any read/write.
procedure InitJsonRpcTransport;

implementation

uses
  SysUtils, jsonparser, u_log;

procedure InitJsonRpcTransport;
begin
  // Ensure LF-only line endings on stdout for cross-platform compatibility
  SetTextLineEnding(Output, #10);
  SetTextLineEnding(StdErr, #10);
end;

function ReadJsonRpcMessage(out AStatus: TReadResult): TJSONObject;
var
  Line: String;
  Data: TJSONData;
begin
  Result := nil;
  AStatus := rrEof;

  // Read lines until we get a non-empty one or hit EOF
  repeat
    if Eof(Input) then
      Exit;  // EOF
    {$I-}
    ReadLn(Line);
    {$I+}
    if IOResult <> 0 then
      Exit;  // Read error
    Line := Trim(Line);
  until Line <> '';

  LogDebug('recv: ' + Line);

  try
    Data := GetJSON(Line);
  except
    on E: Exception do
    begin
      LogError('JSON parse error: ' + E.Message);
      AStatus := rrParseError;
      Exit;
    end;
  end;

  if not (Data is TJSONObject) then
  begin
    LogError('JSON-RPC message is not an object');
    Data.Free;
    AStatus := rrParseError;
    Exit;
  end;

  AStatus := rrSuccess;
  Result := TJSONObject(Data);
end;

procedure WriteJsonRpcMessage(AObj: TJSONObject);
var
  S: String;
begin
  S := AObj.AsJSON;
  LogDebug('send: ' + S);
  WriteLn(S);
  Flush(Output);
end;

function ParseJsonRpcRequest(AObj: TJSONObject): TJsonRpcRequest;
var
  IdData: TJSONData;
begin
  Result.Method := '';
  Result.Params := nil;
  Result.HasId := False;
  Result.IdNum := 0;
  Result.IdStr := '';
  Result.IsStringId := False;

  // Method
  if AObj.IndexOfName('method') >= 0 then
    Result.Method := AObj.Get('method', '');

  // Params (borrowed reference)
  if AObj.IndexOfName('params') >= 0 then
    Result.Params := AObj.Elements['params'];

  // Id
  if AObj.IndexOfName('id') >= 0 then
  begin
    IdData := AObj.Elements['id'];
    if IdData.JSONType = jtNumber then
    begin
      Result.HasId := True;
      Result.IsStringId := False;
      Result.IdNum := IdData.AsInt64;
    end
    else if IdData.JSONType = jtString then
    begin
      Result.HasId := True;
      Result.IsStringId := True;
      Result.IdStr := IdData.AsString;
    end;
    // null id: HasId remains False (notification-like)
  end;
end;

function MakeIdField(const AReq: TJsonRpcRequest): TJSONData;
begin
  if not AReq.HasId then
    Result := TJSONNull.Create
  else if AReq.IsStringId then
    Result := CreateJSON(AReq.IdStr)
  else
    Result := CreateJSON(AReq.IdNum);
end;

function BuildJsonRpcResult(const AReq: TJsonRpcRequest; AResult: TJSONData): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('jsonrpc', '2.0');
  Result.Add('id', MakeIdField(AReq));
  Result.Add('result', AResult);
end;

function BuildJsonRpcError(const AReq: TJsonRpcRequest;
  ACode: Integer; const AMessage: String; AData: TJSONData): TJSONObject;
var
  ErrObj: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('jsonrpc', '2.0');
  Result.Add('id', MakeIdField(AReq));

  ErrObj := TJSONObject.Create;
  ErrObj.Add('code', ACode);
  ErrObj.Add('message', AMessage);
  if AData <> nil then
    ErrObj.Add('data', AData);
  Result.Add('error', ErrObj);
end;

function BuildJsonRpcErrorNoId(ACode: Integer; const AMessage: String): TJSONObject;
var
  ErrObj: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('jsonrpc', '2.0');
  Result.Add('id', TJSONNull.Create);
  ErrObj := TJSONObject.Create;
  ErrObj.Add('code', ACode);
  ErrObj.Add('message', AMessage);
  Result.Add('error', ErrObj);
end;

end.
