unit u_log;

{$mode objfpc}{$H+}

interface

type
  TLogLevel = (llError, llWarn, llInfo, llDebug);

var
  CurrentLogLevel: TLogLevel = llInfo;

procedure Log(ALevel: TLogLevel; const AMsg: String);
procedure LogError(const AMsg: String);
procedure LogWarn(const AMsg: String);
procedure LogInfo(const AMsg: String);
procedure LogDebug(const AMsg: String);
function ParseLogLevel(const AStr: String): TLogLevel;

implementation

uses
  SysUtils;

const
  LOG_LEVEL_NAMES: array[TLogLevel] of String = ('ERROR', 'WARN', 'INFO', 'DEBUG');

procedure Log(ALevel: TLogLevel; const AMsg: String);
begin
  if ALevel > CurrentLogLevel then
    Exit;
  WriteLn(StdErr, '[', LOG_LEVEL_NAMES[ALevel], '] [',
    FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now), '] ', AMsg);
  Flush(StdErr);
end;

procedure LogError(const AMsg: String);
begin
  Log(llError, AMsg);
end;

procedure LogWarn(const AMsg: String);
begin
  Log(llWarn, AMsg);
end;

procedure LogInfo(const AMsg: String);
begin
  Log(llInfo, AMsg);
end;

procedure LogDebug(const AMsg: String);
begin
  Log(llDebug, AMsg);
end;

function ParseLogLevel(const AStr: String): TLogLevel;
var
  S: String;
begin
  S := LowerCase(AStr);
  if S = 'error' then
    Result := llError
  else if S = 'warn' then
    Result := llWarn
  else if S = 'info' then
    Result := llInfo
  else if S = 'debug' then
    Result := llDebug
  else
    Result := llInfo;
end;

end.
