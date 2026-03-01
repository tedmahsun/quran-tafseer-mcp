unit u_format_terminal;

{$mode objfpc}{$H+}

interface

uses
  fpjson;

/// Convert a get_ayah JSON response to terminal-formatted text.
function FormatGetAyahAsTerminal(AData: TJSONObject): String;

/// Convert a get_range JSON response to terminal-formatted text.
function FormatGetRangeAsTerminal(AData: TJSONObject): String;

/// Convert a search JSON response to terminal-formatted text.
function FormatSearchAsTerminal(AData: TJSONObject): String;

/// Convert a list_translations JSON response to terminal-formatted text.
function FormatListTranslationsAsTerminal(AData: TJSONObject): String;

/// Convert a resolve_ref JSON response to terminal-formatted text.
function FormatResolveRefAsTerminal(AData: TJSONObject): String;

/// Convert a diff JSON response to terminal-formatted text.
function FormatDiffAsTerminal(AData: TJSONObject): String;

/// Get maximum verse count for terminal mode based on translation count.
function GetMaxVersesTerminal(ATransCount: Integer): Integer;

implementation

uses
  SysUtils;

// ============================================================================
// HELPERS
// ============================================================================

function SafeGetStr(AObj: TJSONObject; const AKey: String;
  const ADefault: String = ''): String;
begin
  if (AObj <> nil) and (AObj.IndexOfName(AKey) >= 0) then
    Result := AObj.Get(AKey, ADefault)
  else
    Result := ADefault;
end;

function SafeGetInt(AObj: TJSONObject; const AKey: String;
  ADefault: Integer = 0): Integer;
begin
  if (AObj <> nil) and (AObj.IndexOfName(AKey) >= 0) then
    Result := AObj.Get(AKey, ADefault)
  else
    Result := ADefault;
end;

function SafeGetBool(AObj: TJSONObject; const AKey: String;
  ADefault: Boolean = False): Boolean;
begin
  if (AObj <> nil) and (AObj.IndexOfName(AKey) >= 0) then
    Result := AObj.Get(AKey, ADefault)
  else
    Result := ADefault;
end;

function SafeGetFloat(AObj: TJSONObject; const AKey: String;
  ADefault: Double = 0.0): Double;
begin
  if (AObj <> nil) and (AObj.IndexOfName(AKey) >= 0) then
    Result := AObj.Get(AKey, ADefault)
  else
    Result := ADefault;
end;

function SafeGetObj(AObj: TJSONObject; const AKey: String): TJSONObject;
begin
  Result := nil;
  if (AObj <> nil) and (AObj.IndexOfName(AKey) >= 0) and
     (AObj.Elements[AKey].JSONType = jtObject) then
    Result := TJSONObject(AObj.Elements[AKey]);
end;

function SafeGetArr(AObj: TJSONObject; const AKey: String): TJSONArray;
begin
  Result := nil;
  if (AObj <> nil) and (AObj.IndexOfName(AKey) >= 0) and
     (AObj.Elements[AKey].JSONType = jtArray) then
    Result := TJSONArray(AObj.Elements[AKey]);
end;

// ============================================================================
// FORMAT: get_ayah
// ============================================================================

function FormatSingleVerse(AData: TJSONObject): String;
var
  Ref: String;
  ArabicObj: TJSONObject;
  TransArr: TJSONArray;
  TransEntry: TJSONObject;
  I: Integer;
begin
  Ref := SafeGetStr(AData, 'ref');
  Result := '-- ' + Ref + ' --' + LineEnding;

  // Arabic
  ArabicObj := SafeGetObj(AData, 'arabic');
  if ArabicObj <> nil then
  begin
    Result := Result + LineEnding;
    Result := Result + '[Arabic' + #194#183 + ' ' +
      SafeGetStr(ArabicObj, 'corpus_id') + ']' + LineEnding;
    Result := Result + SafeGetStr(ArabicObj, 'text') + LineEnding;
  end;

  // Translations
  TransArr := SafeGetArr(AData, 'translations');
  if TransArr <> nil then
  begin
    for I := 0 to TransArr.Count - 1 do
    begin
      if TransArr.Items[I].JSONType <> jtObject then
        Continue;
      TransEntry := TJSONObject(TransArr.Items[I]);
      Result := Result + LineEnding;
      Result := Result + '[' + SafeGetStr(TransEntry, 'corpus_id') + ']' +
        LineEnding;
      Result := Result + SafeGetStr(TransEntry, 'text') + LineEnding;
    end;
  end;
end;

function FormatGetAyahAsTerminal(AData: TJSONObject): String;
begin
  Result := FormatSingleVerse(AData);
end;

// ============================================================================
// FORMAT: get_range
// ============================================================================

function FormatGetRangeAsTerminal(AData: TJSONObject): String;
var
  VersesArr: TJSONArray;
  VerseObj: TJSONObject;
  I: Integer;
  Truncated: Boolean;
  TotalReq, TotalRet: Integer;
  Continuation: String;
begin
  Result := '';

  VersesArr := SafeGetArr(AData, 'verses');
  if VersesArr = nil then
  begin
    Result := '(No verses returned)';
    Exit;
  end;

  for I := 0 to VersesArr.Count - 1 do
  begin
    if VersesArr.Items[I].JSONType <> jtObject then
      Continue;
    VerseObj := TJSONObject(VersesArr.Items[I]);

    if I > 0 then
      Result := Result + LineEnding;

    Result := Result + FormatSingleVerse(VerseObj);
  end;

  Truncated := SafeGetBool(AData, 'truncated');
  if Truncated then
  begin
    TotalReq := SafeGetInt(AData, 'total_requested');
    TotalRet := SafeGetInt(AData, 'total_returned');
    Continuation := SafeGetStr(AData, 'continuation');

    Result := Result + LineEnding;
    Result := Result + '-- Truncated: showing ' + IntToStr(TotalRet) +
      ' of ' + IntToStr(TotalReq) + ' verses --' + LineEnding;
    if Continuation <> '' then
      Result := Result + Continuation + LineEnding;
  end;
end;

// ============================================================================
// FORMAT: search
// ============================================================================

function FormatSearchAsTerminal(AData: TJSONObject): String;
var
  Query: String;
  HitsArr, SnippetsArr: TJSONArray;
  HitObj, SnipObj: TJSONObject;
  I, J: Integer;
  Score: Double;
begin
  Query := SafeGetStr(AData, 'query');
  HitsArr := SafeGetArr(AData, 'hits');

  if (HitsArr = nil) or (HitsArr.Count = 0) then
  begin
    Result := 'Search: "' + Query + '" -- no results';
    Exit;
  end;

  Result := 'Search: "' + Query + '" -- ' +
    IntToStr(HitsArr.Count) + ' result';
  if HitsArr.Count <> 1 then
    Result := Result + 's';
  Result := Result + LineEnding;

  for I := 0 to HitsArr.Count - 1 do
  begin
    if HitsArr.Items[I].JSONType <> jtObject then
      Continue;
    HitObj := TJSONObject(HitsArr.Items[I]);

    Result := Result + LineEnding;
    Score := SafeGetFloat(HitObj, 'score');
    Result := Result + SafeGetStr(HitObj, 'ref') +
      ' (score: ' + FormatFloat('0.#', Score) + ')' + LineEnding;

    SnippetsArr := SafeGetArr(HitObj, 'snippets');
    if SnippetsArr <> nil then
    begin
      for J := 0 to SnippetsArr.Count - 1 do
      begin
        if SnippetsArr.Items[J].JSONType <> jtObject then
          Continue;
        SnipObj := TJSONObject(SnippetsArr.Items[J]);
        Result := Result + '  [' + SafeGetStr(SnipObj, 'corpus_id') + '] ' +
          SafeGetStr(SnipObj, 'snippet') + LineEnding;
      end;
    end;
  end;
end;

// ============================================================================
// FORMAT: list_translations
// ============================================================================

function FormatListTranslationsAsTerminal(AData: TJSONObject): String;
var
  TransArr, ArabicArr: TJSONArray;
  Entry: TJSONObject;
  I: Integer;
  Id, Title, Author: String;
begin
  Result := '';

  TransArr := SafeGetArr(AData, 'translations');
  if (TransArr <> nil) and (TransArr.Count > 0) then
  begin
    Result := 'Translations (' + IntToStr(TransArr.Count) + '):' + LineEnding;
    for I := 0 to TransArr.Count - 1 do
    begin
      if TransArr.Items[I].JSONType <> jtObject then
        Continue;
      Entry := TJSONObject(TransArr.Items[I]);
      Id := SafeGetStr(Entry, 'id');
      Title := SafeGetStr(Entry, 'title');
      Author := SafeGetStr(Entry, 'translator');

      Result := Result + '  ' + Id;
      // Pad to 24 chars for alignment
      while Length(Result) - LastDelimiter(LineEnding, Result) < 26 do
        Result := Result + ' ';
      Result := Result + Title;
      if Author <> '' then
        Result := Result + ' -- ' + Author;
      Result := Result + LineEnding;
    end;
  end
  else
    Result := 'Translations: (none)' + LineEnding;

  ArabicArr := SafeGetArr(AData, 'arabic');
  if (ArabicArr <> nil) and (ArabicArr.Count > 0) then
  begin
    Result := Result + LineEnding;
    Result := Result + 'Arabic Editions (' + IntToStr(ArabicArr.Count) +
      '):' + LineEnding;
    for I := 0 to ArabicArr.Count - 1 do
    begin
      if ArabicArr.Items[I].JSONType <> jtObject then
        Continue;
      Entry := TJSONObject(ArabicArr.Items[I]);
      Id := SafeGetStr(Entry, 'id');
      Title := SafeGetStr(Entry, 'title');

      Result := Result + '  ' + Id;
      while Length(Result) - LastDelimiter(LineEnding, Result) < 26 do
        Result := Result + ' ';
      Result := Result + Title + LineEnding;
    end;
  end;
end;

// ============================================================================
// FORMAT: resolve_ref
// ============================================================================

function FormatResolveRefAsTerminal(AData: TJSONObject): String;
var
  NormRef, SurahName: String;
  Surah, Ayah, AyahCount: Integer;
begin
  NormRef := SafeGetStr(AData, 'normalized_ref');
  SurahName := SafeGetStr(AData, 'surah_name');
  Surah := SafeGetInt(AData, 'surah');
  Ayah := SafeGetInt(AData, 'ayah');
  AyahCount := SafeGetInt(AData, 'ayah_count');

  Result := NormRef + LineEnding;

  if SurahName <> '' then
  begin
    Result := Result + 'Surah ' + IntToStr(Surah) + ': ' + SurahName;
    if Ayah > 0 then
      Result := Result + ', Ayah ' + IntToStr(Ayah)
    else if AyahCount > 0 then
      Result := Result + ' (' + IntToStr(AyahCount) + ' ayat)';
    Result := Result + LineEnding;
  end;
end;

// ============================================================================
// FORMAT: diff
// ============================================================================

function FormatDiffAsTerminal(AData: TJSONObject): String;
var
  Ref, BaseId, OpStr, OpText: String;
  DiffsArr, OpsArr: TJSONArray;
  DiffEntry, StatsObj, OpObj: TJSONObject;
  I, J, EqCount, DelCount, InsCount: Integer;
  Sim: Double;
begin
  Ref := SafeGetStr(AData, 'ref');
  BaseId := SafeGetStr(AData, 'base');

  Result := '-- Diff ' + Ref + ' --' + LineEnding;
  Result := Result + 'Base: ' + BaseId + LineEnding;

  DiffsArr := SafeGetArr(AData, 'diffs');
  if (DiffsArr = nil) or (DiffsArr.Count = 0) then
  begin
    Result := Result + '(No diffs)' + LineEnding;
    Exit;
  end;

  for I := 0 to DiffsArr.Count - 1 do
  begin
    if DiffsArr.Items[I].JSONType <> jtObject then
      Continue;
    DiffEntry := TJSONObject(DiffsArr.Items[I]);

    Result := Result + LineEnding;
    Result := Result + 'vs ' + SafeGetStr(DiffEntry, 'corpus_id') + ':' +
      LineEnding;

    // Show ops
    OpsArr := SafeGetArr(DiffEntry, 'ops');
    if OpsArr <> nil then
    begin
      for J := 0 to OpsArr.Count - 1 do
      begin
        if OpsArr.Items[J].JSONType <> jtObject then
          Continue;
        OpObj := TJSONObject(OpsArr.Items[J]);
        OpStr := SafeGetStr(OpObj, 'op');
        OpText := SafeGetStr(OpObj, 'text');

        if OpStr = 'equal' then
          Result := Result + '  = ' + OpText + LineEnding
        else if OpStr = 'delete' then
          Result := Result + '  - ' + OpText + LineEnding
        else if OpStr = 'insert' then
          Result := Result + '  + ' + OpText + LineEnding;
      end;
    end;

    // Show stats
    StatsObj := SafeGetObj(DiffEntry, 'stats');
    if StatsObj <> nil then
    begin
      EqCount := SafeGetInt(StatsObj, 'equal');
      DelCount := SafeGetInt(StatsObj, 'deleted');
      InsCount := SafeGetInt(StatsObj, 'inserted');
      Sim := SafeGetFloat(StatsObj, 'similarity');
      Result := Result + '  [equal=' + IntToStr(EqCount) +
        ' del=' + IntToStr(DelCount) +
        ' ins=' + IntToStr(InsCount) +
        ' sim=' + FormatFloat('0.##', Sim) + ']' + LineEnding;
    end;
  end;
end;

// ============================================================================
// TERMINAL VERSE LIMITS
// ============================================================================

function GetMaxVersesTerminal(ATransCount: Integer): Integer;
begin
  if ATransCount <= 2 then
    Result := 15
  else if ATransCount <= 6 then
    Result := 10
  else
    Result := 7;
end;

end.
