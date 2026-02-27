program quranref;

{$mode objfpc}{$H+}

uses
  SysUtils,
  u_log,
  u_jsonrpc,
  u_mcp,
  u_quran_metadata;

procedure PrintUsage;
begin
  WriteLn(StdErr, 'Usage: quranref <command> [options]');
  WriteLn(StdErr, '');
  WriteLn(StdErr, 'Commands:');
  WriteLn(StdErr, '  mcp          Run as MCP server over stdio');
  WriteLn(StdErr, '  init         First-run setup (not yet implemented)');
  WriteLn(StdErr, '  setup        Re-run setup (not yet implemented)');
  WriteLn(StdErr, '  catalog      Browse translation catalog (not yet implemented)');
  WriteLn(StdErr, '  corpus       Manage corpora (not yet implemented)');
  WriteLn(StdErr, '  index        Manage indexes (not yet implemented)');
  WriteLn(StdErr, '');
  WriteLn(StdErr, 'Options:');
  WriteLn(StdErr, '  --data <path>          Data root directory (required for mcp)');
  WriteLn(StdErr, '  --log-level <level>    Log level: error, warn, info, debug');
  WriteLn(StdErr, '  --version              Show version');
  WriteLn(StdErr, '  --help                 Show this help');
end;

procedure PrintVersion;
begin
  WriteLn(SERVER_NAME, ' v', SERVER_VERSION);
end;

function GetParam(const AName: String): String;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to ParamCount - 1 do
  begin
    if ParamStr(I) = AName then
    begin
      if I < ParamCount then
        Result := ParamStr(I + 1);
      Exit;
    end;
  end;
end;

function HasParam(const AName: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    if ParamStr(I) = AName then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

var
  Cmd, DataRoot, LogLevelStr: String;
begin
  // Handle --version and --help before anything else
  if HasParam('--version') then
  begin
    PrintVersion;
    Halt(0);
  end;

  if HasParam('--help') or HasParam('-h') or (ParamCount = 0) then
  begin
    PrintUsage;
    Halt(0);
  end;

  // Parse --log-level
  LogLevelStr := GetParam('--log-level');
  if LogLevelStr <> '' then
    CurrentLogLevel := ParseLogLevel(LogLevelStr);

  // Get command
  Cmd := ParamStr(1);

  if Cmd = 'mcp' then
  begin
    DataRoot := GetParam('--data');
    if DataRoot = '' then
    begin
      WriteLn(StdErr, 'Error: --data <path> is required for mcp command');
      Halt(1);
    end;

    // Validate data root exists (or create it)
    if not DirectoryExists(DataRoot) then
    begin
      if not ForceDirectories(DataRoot) then
      begin
        WriteLn(StdErr, 'Error: Cannot create data root: ' + DataRoot);
        Halt(1);
      end;
    end;

    LogInfo('Data root: ' + DataRoot);
    InitJsonRpcTransport;
    RunMcpLoop;
  end
  else if (Cmd = 'init') or (Cmd = 'setup') or (Cmd = 'catalog') or
          (Cmd = 'corpus') or (Cmd = 'index') then
  begin
    WriteLn(StdErr, 'Command "', Cmd, '" is not yet implemented.');
    Halt(1);
  end
  else
  begin
    WriteLn(StdErr, 'Unknown command: ', Cmd);
    PrintUsage;
    Halt(1);
  end;
end.
