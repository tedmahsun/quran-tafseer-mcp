unit u_tools_quran;

{$mode objfpc}{$H+}

interface

uses
  fpjson, u_jsonrpc;

// ============================================================================
// SHARED TOOL HELPERS (used by u_tools_quran and u_tools_setup)
// ============================================================================

/// Build an MCP tools/call success response wrapping a content array.
function BuildToolResult(const AReq: TJsonRpcRequest;
  AContent: TJSONArray): TJSONObject;

/// Build an MCP tools/call error response (isError: true) with a text message.
function BuildToolError(const AReq: TJsonRpcRequest;
  ACode: Integer; const AMessage: String): TJSONObject;

/// Build a single text content item for MCP tool results.
function MakeTextContent(const AText: String): TJSONArray;

// ============================================================================
// TOOL HANDLERS
// ============================================================================

/// Handle quran.list_translations tool call.
function HandleListTranslations(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;

/// Handle quran.get_ayah tool call.
function HandleGetAyah(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;

/// Handle quran.get_range tool call.
function HandleGetRange(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;

/// Handle quran.resolve_ref tool call.
function HandleResolveRef(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;

/// Handle quran.search tool call.
function HandleSearch(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;

/// Handle quran.diff tool call.
function HandleDiff(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;

implementation

uses
  SysUtils, u_log, u_mcp, u_corpus_manifest, u_corpus_reader,
  u_corpus_store, u_quran_metadata, u_index_sqlite, u_format_terminal;

// ============================================================================
// HELPERS
// ============================================================================

/// Build an MCP tools/call success response wrapping a content array.
function BuildToolResult(const AReq: TJsonRpcRequest;
  AContent: TJSONArray): TJSONObject;
var
  ResObj: TJSONObject;
begin
  ResObj := TJSONObject.Create;
  ResObj.Add('content', AContent);
  Result := BuildJsonRpcResult(AReq, ResObj);
end;

/// Build an MCP tools/call error response (isError: true) with a text message.
function BuildToolError(const AReq: TJsonRpcRequest;
  ACode: Integer; const AMessage: String): TJSONObject;
var
  ResObj, ContentItem: TJSONObject;
  ContentArr: TJSONArray;
begin
  ResObj := TJSONObject.Create;
  ResObj.Add('isError', True);

  ContentArr := TJSONArray.Create;
  ContentItem := TJSONObject.Create;
  ContentItem.Add('type', 'text');
  ContentItem.Add('text', AMessage);
  ContentArr.Add(ContentItem);
  ResObj.Add('content', ContentArr);

  Result := BuildJsonRpcResult(AReq, ResObj);
end;

/// Build a single text content item for MCP tool results.
function MakeTextContent(const AText: String): TJSONArray;
var
  Item: TJSONObject;
begin
  Result := TJSONArray.Create;
  Item := TJSONObject.Create;
  Item.Add('type', 'text');
  Item.Add('text', AText);
  Result.Add(Item);
end;

/// Check if the format parameter requests terminal output.
function IsTerminalFormat(AArgs: TJSONObject): Boolean;
var
  Fmt: String;
begin
  Result := False;
  if AArgs = nil then
    Exit;
  Fmt := AArgs.Get('format', '');
  Result := (LowerCase(Fmt) = 'terminal');
end;

// ============================================================================
// quran.list_translations
// ============================================================================

function HandleListTranslations(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;
var
  LangFilter: String;
  TransArr, ArabicArr: TJSONArray;
  ResObj, Entry: TJSONObject;
  I: Integer;
  Store: PVerseStore;
  ResultJson: TJSONObject;
begin
  // Parse optional lang filter
  LangFilter := '';
  if AArgs <> nil then
    LangFilter := AArgs.Get('lang', '');

  TransArr := TJSONArray.Create;
  ArabicArr := TJSONArray.Create;

  for I := 0 to GetCorpusCount - 1 do
  begin
    Store := GetCorpusByIndex(I);
    if Store = nil then
      Continue;

    // Apply language filter
    if (LangFilter <> '') and (Store^.Manifest.Language <> LangFilter) then
      Continue;

    Entry := TJSONObject.Create;
    Entry.Add('id', Store^.Manifest.Id);
    Entry.Add('title', Store^.Manifest.Title);

    if Store^.Manifest.Kind = ckArabic then
    begin
      Entry.Add('has_mapping', True);
      ArabicArr.Add(Entry);
    end
    else
    begin
      Entry.Add('translator', Store^.Manifest.Author);
      Entry.Add('source', Store^.Manifest.Source);
      Entry.Add('license_note', Store^.Manifest.LicenseNote);
      Entry.Add('format', 'tsv_surah_ayah_text');
      Entry.Add('has_mapping', True);
      TransArr.Add(Entry);
    end;
  end;

  ResObj := TJSONObject.Create;
  ResObj.Add('translations', TransArr);
  ResObj.Add('arabic', ArabicArr);

  if IsTerminalFormat(AArgs) then
    Result := BuildToolResult(AReq,
      MakeTextContent(FormatListTranslationsAsTerminal(ResObj)))
  else
    Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
  ResObj.Free;
end;

// ============================================================================
// quran.get_ayah
// ============================================================================

function HandleGetAyah(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;
var
  Surah, Ayah, I: Integer;
  IncludeArabic: Boolean;
  ArabicId: String;
  TransIds: TJSONArray;
  UseAllTrans: Boolean;
  ResObj, ArabicObj, TransEntry, CitEntry: TJSONObject;
  TransArr, CitArr: TJSONArray;
  Store: PVerseStore;
  Text, TransId: String;
begin
  if AArgs = nil then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing arguments for quran.get_ayah');
    Exit;
  end;

  // Parse surah and ayah (required)
  Surah := AArgs.Get('surah', 0);
  Ayah := AArgs.Get('ayah', 0);

  if (Surah = 0) or (Ayah = 0) then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing required parameters: surah, ayah');
    Exit;
  end;

  // Validate reference
  if (Surah < 1) or (Surah > SURAH_COUNT) then
  begin
    Result := BuildToolError(AReq, ERR_VERSE_OUT_OF_RANGE,
      'Surah ' + IntToStr(Surah) + ' is out of range (1-' +
      IntToStr(SURAH_COUNT) + ').');
    Exit;
  end;

  if not IsValidReference(Surah, Ayah) then
  begin
    Result := BuildToolError(AReq, ERR_VERSE_OUT_OF_RANGE,
      'Ayah ' + IntToStr(Ayah) + ' is out of range for surah ' +
      IntToStr(Surah) + ' (max: ' + IntToStr(GetAyahCount(Surah)) + ').');
    Exit;
  end;

  // Parse include_arabic (default true)
  IncludeArabic := AArgs.Get('include_arabic', True);

  // Parse arabic_id (default: first Arabic corpus found)
  ArabicId := AArgs.Get('arabic_id', '');

  // Parse translations param
  TransIds := nil;
  UseAllTrans := False;
  if AArgs.IndexOfName('translations') >= 0 then
  begin
    if AArgs.Elements['translations'].JSONType = jtString then
    begin
      if AArgs.Get('translations', '') = 'all' then
        UseAllTrans := True;
    end
    else if AArgs.Elements['translations'].JSONType = jtArray then
      TransIds := AArgs.Arrays['translations'];
  end
  else
    UseAllTrans := True;  // default: all

  // Build response
  ResObj := TJSONObject.Create;
  ResObj.Add('ref', 'Q ' + IntToStr(Surah) + ':' + IntToStr(Ayah));

  CitArr := TJSONArray.Create;

  // Arabic
  if IncludeArabic then
  begin
    // Find Arabic corpus
    if ArabicId = '' then
    begin
      // Use first Arabic corpus found
      for I := 0 to GetCorpusCount - 1 do
      begin
        Store := GetCorpusByIndex(I);
        if (Store <> nil) and (Store^.Manifest.Kind = ckArabic) then
        begin
          ArabicId := Store^.Manifest.Id;
          Break;
        end;
      end;
    end;

    if ArabicId <> '' then
    begin
      Text := LookupVerse(ArabicId, Surah, Ayah);
      ArabicObj := TJSONObject.Create;
      ArabicObj.Add('corpus_id', ArabicId);
      ArabicObj.Add('text', Text);
      ResObj.Add('arabic', ArabicObj);

      // Citation
      Store := FindCorpus(ArabicId);
      if Store <> nil then
      begin
        CitEntry := TJSONObject.Create;
        CitEntry.Add('corpus_id', ArabicId);
        CitEntry.Add('checksum', Store^.Manifest.Checksum);
        CitArr.Add(CitEntry);
      end;
    end
    else
      ResObj.Add('arabic', TJSONNull.Create);
  end;

  // Translations
  TransArr := TJSONArray.Create;

  if UseAllTrans then
  begin
    // Add all translation corpora
    for I := 0 to GetCorpusCount - 1 do
    begin
      Store := GetCorpusByIndex(I);
      if (Store = nil) or (Store^.Manifest.Kind <> ckTranslation) then
        Continue;

      Text := GetVerse(Store^, Surah, Ayah);
      TransEntry := TJSONObject.Create;
      TransEntry.Add('corpus_id', Store^.Manifest.Id);
      TransEntry.Add('text', Text);
      TransArr.Add(TransEntry);

      CitEntry := TJSONObject.Create;
      CitEntry.Add('corpus_id', Store^.Manifest.Id);
      CitEntry.Add('checksum', Store^.Manifest.Checksum);
      CitArr.Add(CitEntry);
    end;
  end
  else if TransIds <> nil then
  begin
    // Add specified translations
    for I := 0 to TransIds.Count - 1 do
    begin
      TransId := TransIds.Strings[I];
      Store := FindCorpus(TransId);
      if Store = nil then
      begin
        // Unknown corpus — add error entry
        TransEntry := TJSONObject.Create;
        TransEntry.Add('corpus_id', TransId);
        TransEntry.Add('text', '');
        TransEntry.Add('error', 'Corpus not found: ' + TransId);
        TransArr.Add(TransEntry);
        Continue;
      end;

      Text := GetVerse(Store^, Surah, Ayah);
      TransEntry := TJSONObject.Create;
      TransEntry.Add('corpus_id', TransId);
      TransEntry.Add('text', Text);
      TransArr.Add(TransEntry);

      CitEntry := TJSONObject.Create;
      CitEntry.Add('corpus_id', TransId);
      CitEntry.Add('checksum', Store^.Manifest.Checksum);
      CitArr.Add(CitEntry);
    end;
  end;

  ResObj.Add('translations', TransArr);
  ResObj.Add('citations', CitArr);

  if IsTerminalFormat(AArgs) then
    Result := BuildToolResult(AReq,
      MakeTextContent(FormatGetAyahAsTerminal(ResObj)))
  else
    Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
  ResObj.Free;
end;

// ============================================================================
// quran.get_range
// ============================================================================

function CountRequestedTranslations(AArgs: TJSONObject): Integer;
var
  TransIds: TJSONArray;
  I: Integer;
  Store: PVerseStore;
begin
  Result := 0;
  if AArgs = nil then
  begin
    // Default: all translations
    for I := 0 to GetCorpusCount - 1 do
    begin
      Store := GetCorpusByIndex(I);
      if (Store <> nil) and (Store^.Manifest.Kind = ckTranslation) then
        Inc(Result);
    end;
    Exit;
  end;

  if AArgs.IndexOfName('translations') >= 0 then
  begin
    if AArgs.Elements['translations'].JSONType = jtString then
    begin
      if AArgs.Get('translations', '') = 'all' then
      begin
        for I := 0 to GetCorpusCount - 1 do
        begin
          Store := GetCorpusByIndex(I);
          if (Store <> nil) and (Store^.Manifest.Kind = ckTranslation) then
            Inc(Result);
        end;
      end;
    end
    else if AArgs.Elements['translations'].JSONType = jtArray then
    begin
      TransIds := AArgs.Arrays['translations'];
      // Count only IDs that correspond to loaded corpora
      for I := 0 to TransIds.Count - 1 do
      begin
        Store := FindCorpus(TransIds.Strings[I]);
        if Store <> nil then
          Inc(Result);
      end;
    end;
  end
  else
  begin
    // Default: all
    for I := 0 to GetCorpusCount - 1 do
    begin
      Store := GetCorpusByIndex(I);
      if (Store <> nil) and (Store^.Manifest.Kind = ckTranslation) then
        Inc(Result);
    end;
  end;
end;

function GetMaxVerses(ATransCount: Integer): Integer;
begin
  if ATransCount <= 2 then
    Result := 25
  else if ATransCount <= 6 then
    Result := 15
  else
    Result := 10;
end;

function HandleGetRange(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;
var
  Surah, StartAyah, EndAyah, MaxAyah, I, J, A: Integer;
  IncludeArabic: Boolean;
  ArabicId: String;
  TransIds: TJSONArray;
  UseAllTrans: Boolean;
  ResObj, VerseObj, ArabicObj, TransEntry: TJSONObject;
  VersesArr, TransArr, CitArr: TJSONArray;
  Store: PVerseStore;
  Text, TransId: String;
  TransCount, MaxVerse, TotalRequested, TotalReturned: Integer;
  Truncated: Boolean;
  CitationIds: array of String;
  CitationCount: Integer;

  function HasCitation(const AId: String): Boolean;
  var
    K: Integer;
  begin
    Result := False;
    for K := 0 to CitationCount - 1 do
      if CitationIds[K] = AId then
      begin
        Result := True;
        Exit;
      end;
  end;

  procedure AddCitation(const AId: String);
  var
    S: PVerseStore;
    Cit: TJSONObject;
  begin
    if HasCitation(AId) then
      Exit;
    S := FindCorpus(AId);
    if S = nil then
      Exit;
    Cit := TJSONObject.Create;
    Cit.Add('corpus_id', AId);
    Cit.Add('checksum', S^.Manifest.Checksum);
    CitArr.Add(Cit);
    if CitationCount < Length(CitationIds) then
    begin
      CitationIds[CitationCount] := AId;
      Inc(CitationCount);
    end;
  end;

begin
  if AArgs = nil then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing arguments for quran.get_range');
    Exit;
  end;

  // Parse required params
  Surah := AArgs.Get('surah', 0);
  StartAyah := AArgs.Get('start_ayah', 0);
  EndAyah := AArgs.Get('end_ayah', 0);

  if (Surah = 0) or (StartAyah = 0) or (EndAyah = 0) then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing required parameters: surah, start_ayah, end_ayah');
    Exit;
  end;

  // Validate surah
  if (Surah < 1) or (Surah > SURAH_COUNT) then
  begin
    Result := BuildToolError(AReq, ERR_VERSE_OUT_OF_RANGE,
      'Surah ' + IntToStr(Surah) + ' is out of range (1-' +
      IntToStr(SURAH_COUNT) + ').');
    Exit;
  end;

  MaxAyah := GetAyahCount(Surah);

  // Validate start_ayah
  if StartAyah < 1 then
  begin
    Result := BuildToolError(AReq, ERR_VERSE_OUT_OF_RANGE,
      'start_ayah must be >= 1.');
    Exit;
  end;

  // Validate end >= start
  if EndAyah < StartAyah then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'end_ayah (' + IntToStr(EndAyah) + ') must be >= start_ayah (' +
      IntToStr(StartAyah) + ').');
    Exit;
  end;

  // Validate end_ayah within surah bounds
  if EndAyah > MaxAyah then
  begin
    Result := BuildToolError(AReq, ERR_VERSE_OUT_OF_RANGE,
      'end_ayah ' + IntToStr(EndAyah) + ' is out of range for surah ' +
      IntToStr(Surah) + ' (max: ' + IntToStr(MaxAyah) +
      '). Note: quran.get_range is limited to a single surah. ' +
      'Use multiple calls for cross-surah ranges.');
    Exit;
  end;

  // Validate start_ayah within surah bounds
  if StartAyah > MaxAyah then
  begin
    Result := BuildToolError(AReq, ERR_VERSE_OUT_OF_RANGE,
      'start_ayah ' + IntToStr(StartAyah) + ' is out of range for surah ' +
      IntToStr(Surah) + ' (max: ' + IntToStr(MaxAyah) + ').');
    Exit;
  end;

  // Parse optional params
  IncludeArabic := AArgs.Get('include_arabic', True);
  ArabicId := AArgs.Get('arabic_id', '');

  // Parse translations param (same logic as get_ayah)
  TransIds := nil;
  UseAllTrans := False;
  if AArgs.IndexOfName('translations') >= 0 then
  begin
    if AArgs.Elements['translations'].JSONType = jtString then
    begin
      if AArgs.Get('translations', '') = 'all' then
        UseAllTrans := True;
    end
    else if AArgs.Elements['translations'].JSONType = jtArray then
      TransIds := AArgs.Arrays['translations'];
  end
  else
    UseAllTrans := True;

  // Dynamic verse limit based on translation count and format
  TransCount := CountRequestedTranslations(AArgs);
  if IsTerminalFormat(AArgs) then
    MaxVerse := GetMaxVersesTerminal(TransCount)
  else
    MaxVerse := GetMaxVerses(TransCount);

  TotalRequested := EndAyah - StartAyah + 1;
  Truncated := TotalRequested > MaxVerse;
  if Truncated then
    TotalReturned := MaxVerse
  else
    TotalReturned := TotalRequested;

  // Find Arabic corpus ID if needed
  if IncludeArabic and (ArabicId = '') then
  begin
    for I := 0 to GetCorpusCount - 1 do
    begin
      Store := GetCorpusByIndex(I);
      if (Store <> nil) and (Store^.Manifest.Kind = ckArabic) then
      begin
        ArabicId := Store^.Manifest.Id;
        Break;
      end;
    end;
  end;

  // Build response
  SetLength(CitationIds, GetCorpusCount + 1);
  CitationCount := 0;

  VersesArr := TJSONArray.Create;
  CitArr := TJSONArray.Create;

  for A := StartAyah to StartAyah + TotalReturned - 1 do
  begin
    VerseObj := TJSONObject.Create;
    VerseObj.Add('ref', 'Q ' + IntToStr(Surah) + ':' + IntToStr(A));

    // Arabic
    if IncludeArabic then
    begin
      if ArabicId <> '' then
      begin
        Text := LookupVerse(ArabicId, Surah, A);
        ArabicObj := TJSONObject.Create;
        ArabicObj.Add('corpus_id', ArabicId);
        ArabicObj.Add('text', Text);
        VerseObj.Add('arabic', ArabicObj);
        AddCitation(ArabicId);
      end
      else
        VerseObj.Add('arabic', TJSONNull.Create);
    end;

    // Translations
    TransArr := TJSONArray.Create;

    if UseAllTrans then
    begin
      for J := 0 to GetCorpusCount - 1 do
      begin
        Store := GetCorpusByIndex(J);
        if (Store = nil) or (Store^.Manifest.Kind <> ckTranslation) then
          Continue;

        Text := GetVerse(Store^, Surah, A);
        TransEntry := TJSONObject.Create;
        TransEntry.Add('corpus_id', Store^.Manifest.Id);
        TransEntry.Add('text', Text);
        TransArr.Add(TransEntry);
        AddCitation(Store^.Manifest.Id);
      end;
    end
    else if TransIds <> nil then
    begin
      for J := 0 to TransIds.Count - 1 do
      begin
        TransId := TransIds.Strings[J];
        Store := FindCorpus(TransId);
        if Store = nil then
        begin
          TransEntry := TJSONObject.Create;
          TransEntry.Add('corpus_id', TransId);
          TransEntry.Add('text', '');
          TransEntry.Add('error', 'Corpus not found: ' + TransId);
          TransArr.Add(TransEntry);
          Continue;
        end;

        Text := GetVerse(Store^, Surah, A);
        TransEntry := TJSONObject.Create;
        TransEntry.Add('corpus_id', TransId);
        TransEntry.Add('text', Text);
        TransArr.Add(TransEntry);
        AddCitation(TransId);
      end;
    end;

    VerseObj.Add('translations', TransArr);
    VersesArr.Add(VerseObj);
  end;

  ResObj := TJSONObject.Create;
  ResObj.Add('verses', VersesArr);
  ResObj.Add('truncated', Truncated);
  ResObj.Add('total_requested', TotalRequested);
  ResObj.Add('total_returned', TotalReturned);
  if Truncated then
    ResObj.Add('continuation',
      'Range was truncated to ' + IntToStr(TotalReturned) + ' verses. ' +
      'To get the rest, call quran.get_range with start_ayah=' +
      IntToStr(StartAyah + TotalReturned) + '.');
  ResObj.Add('citations', CitArr);

  if IsTerminalFormat(AArgs) then
    Result := BuildToolResult(AReq,
      MakeTextContent(FormatGetRangeAsTerminal(ResObj)))
  else
    Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
  ResObj.Free;
end;

// ============================================================================
// quran.resolve_ref
// ============================================================================

function HandleResolveRef(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;
var
  RefStr, SurahPart, AyahPart: String;
  Surah, Ayah, I, ColonPos: Integer;
  ResObj: TJSONObject;
  SurahInfo: PSurahInfo;
begin
  if AArgs = nil then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing arguments for quran.resolve_ref');
    Exit;
  end;

  RefStr := AArgs.Get('ref', '');
  if RefStr = '' then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing required parameter: ref');
    Exit;
  end;

  LogDebug('resolve_ref: input="' + RefStr + '"');

  // Strip leading "Q " or "q " if present
  if (Length(RefStr) >= 2) and ((Copy(RefStr, 1, 2) = 'Q ') or
    (Copy(RefStr, 1, 2) = 'q ')) then
    RefStr := Trim(Copy(RefStr, 3, Length(RefStr)));

  Surah := 0;
  Ayah := 0;

  // Try to find a colon separator
  ColonPos := Pos(':', RefStr);
  if ColonPos > 0 then
  begin
    SurahPart := Trim(Copy(RefStr, 1, ColonPos - 1));
    AyahPart := Trim(Copy(RefStr, ColonPos + 1, Length(RefStr)));

    // Try surah as number
    Surah := StrToIntDef(SurahPart, 0);
    if Surah = 0 then
      Surah := FindSurahByName(SurahPart);

    Ayah := StrToIntDef(AyahPart, 0);
  end
  else
  begin
    // No colon — try "SurahName Ayah" or "Number Ayah"
    // Find last space that separates name from ayah
    I := Length(RefStr);
    while (I > 0) and (RefStr[I] <> ' ') do
      Dec(I);

    if I > 0 then
    begin
      SurahPart := Trim(Copy(RefStr, 1, I - 1));
      AyahPart := Trim(Copy(RefStr, I + 1, Length(RefStr)));

      Ayah := StrToIntDef(AyahPart, 0);
      if Ayah > 0 then
      begin
        Surah := StrToIntDef(SurahPart, 0);
        if Surah = 0 then
          Surah := FindSurahByName(SurahPart);
      end
      else
      begin
        // Maybe the whole thing is a surah name with no ayah
        Surah := FindSurahByName(RefStr);
        Ayah := 0;
      end;
    end
    else
    begin
      // Single token — could be surah number or name
      Surah := StrToIntDef(RefStr, 0);
      if Surah = 0 then
        Surah := FindSurahByName(RefStr);
    end;
  end;

  if Surah = 0 then
  begin
    Result := BuildToolError(AReq, ERR_VERSE_OUT_OF_RANGE,
      'Cannot resolve reference: "' + AArgs.Get('ref', '') + '"');
    Exit;
  end;

  // If no ayah specified, return surah info only
  if Ayah = 0 then
  begin
    SurahInfo := GetSurahByNumber(Surah);
    ResObj := TJSONObject.Create;
    ResObj.Add('surah', Surah);
    if SurahInfo <> nil then
    begin
      ResObj.Add('surah_name', SurahInfo^.TranslitName);
      ResObj.Add('ayah_count', Integer(SurahInfo^.AyahCount));
    end;
    ResObj.Add('normalized_ref', 'Q ' + IntToStr(Surah));
    if IsTerminalFormat(AArgs) then
      Result := BuildToolResult(AReq,
        MakeTextContent(FormatResolveRefAsTerminal(ResObj)))
    else
      Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
    ResObj.Free;
    Exit;
  end;

  // Validate
  if not IsValidReference(Surah, Ayah) then
  begin
    Result := BuildToolError(AReq, ERR_VERSE_OUT_OF_RANGE,
      'Ayah ' + IntToStr(Ayah) + ' is out of range for surah ' +
      IntToStr(Surah) + ' (max: ' + IntToStr(GetAyahCount(Surah)) + ').');
    Exit;
  end;

  SurahInfo := GetSurahByNumber(Surah);
  ResObj := TJSONObject.Create;
  ResObj.Add('surah', Surah);
  ResObj.Add('ayah', Ayah);
  if SurahInfo <> nil then
    ResObj.Add('surah_name', SurahInfo^.TranslitName);
  ResObj.Add('normalized_ref', 'Q ' + IntToStr(Surah) + ':' + IntToStr(Ayah));

  if IsTerminalFormat(AArgs) then
    Result := BuildToolResult(AReq,
      MakeTextContent(FormatResolveRefAsTerminal(ResObj)))
  else
    Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
  ResObj.Free;
end;

// ============================================================================
// quran.search
// ============================================================================

function HandleSearch(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;
type
  TMergedHit = record
    Surah: Integer;
    Ayah: Integer;
    BestScore: Double;
    Snippets: TJSONArray;
  end;
var
  Query: String;
  Limit, I, J, K: Integer;
  TransIds: TJSONArray;
  UseAllTrans: Boolean;
  Store: PVerseStore;
  CorpusId: String;
  Results: TSearchResults;
  DataRoot: String;
  MergedHits: array of TMergedHit;
  MergedCount: Integer;
  SnipObj, HitObj, ResObj: TJSONObject;
  HitsArr: TJSONArray;

  procedure AddMergedHit(ASurah, AAyah: Integer; AScore: Double;
    const ACorpusId, ASnippet: String);
  var
    M: Integer;
  begin
    // Find existing merged hit for this (surah, ayah)
    for M := 0 to MergedCount - 1 do
    begin
      if (MergedHits[M].Surah = ASurah) and (MergedHits[M].Ayah = AAyah) then
      begin
        if AScore > MergedHits[M].BestScore then
          MergedHits[M].BestScore := AScore;
        SnipObj := TJSONObject.Create;
        SnipObj.Add('corpus_id', ACorpusId);
        SnipObj.Add('snippet', ASnippet);
        MergedHits[M].Snippets.Add(SnipObj);
        Exit;
      end;
    end;
    // New hit
    if MergedCount >= Length(MergedHits) then
      SetLength(MergedHits, MergedCount + 64);
    MergedHits[MergedCount].Surah := ASurah;
    MergedHits[MergedCount].Ayah := AAyah;
    MergedHits[MergedCount].BestScore := AScore;
    MergedHits[MergedCount].Snippets := TJSONArray.Create;
    SnipObj := TJSONObject.Create;
    SnipObj.Add('corpus_id', ACorpusId);
    SnipObj.Add('snippet', ASnippet);
    MergedHits[MergedCount].Snippets.Add(SnipObj);
    Inc(MergedCount);
  end;

  procedure SortMergedByScore;
  var
    Tmp: TMergedHit;
    P, Q: Integer;
  begin
    // Simple insertion sort (small N)
    for P := 1 to MergedCount - 1 do
    begin
      Tmp := MergedHits[P];
      Q := P - 1;
      while (Q >= 0) and (MergedHits[Q].BestScore < Tmp.BestScore) do
      begin
        MergedHits[Q + 1] := MergedHits[Q];
        Dec(Q);
      end;
      MergedHits[Q + 1] := Tmp;
    end;
  end;

begin
  if AArgs = nil then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing arguments for quran.search');
    Exit;
  end;

  Query := AArgs.Get('query', '');
  if Query = '' then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing required parameter: query');
    Exit;
  end;

  Limit := AArgs.Get('limit', 20);
  if Limit < 1 then Limit := 1;
  if Limit > 50 then Limit := 50;

  // Parse translations param
  TransIds := nil;
  UseAllTrans := False;
  if AArgs.IndexOfName('translations') >= 0 then
  begin
    if AArgs.Elements['translations'].JSONType = jtArray then
      TransIds := AArgs.Arrays['translations']
    else if AArgs.Elements['translations'].JSONType = jtString then
    begin
      if AArgs.Get('translations', '') = 'all' then
        UseAllTrans := True;
    end;
  end
  else
    UseAllTrans := True;

  DataRoot := GetDataRoot;
  MergedCount := 0;
  SetLength(MergedHits, 64);

  if UseAllTrans then
  begin
    // Search all translation corpora
    for I := 0 to GetCorpusCount - 1 do
    begin
      Store := GetCorpusByIndex(I);
      if (Store = nil) or (Store^.Manifest.Kind <> ckTranslation) then
        Continue;

      CorpusId := Store^.Manifest.Id;
      if not IndexExists(CorpusId, DataRoot) then
      begin
        LogWarn('No index for corpus: ' + CorpusId + ' (skipping search)');
        Continue;
      end;

      if SearchIndex(CorpusId, DataRoot, Query, Limit, Results) then
      begin
        for J := 0 to High(Results) do
          AddMergedHit(Results[J].Surah, Results[J].Ayah,
            Results[J].Score, CorpusId, Results[J].Snippet);
      end;
    end;
  end
  else if TransIds <> nil then
  begin
    // Search specified corpora
    for I := 0 to TransIds.Count - 1 do
    begin
      CorpusId := TransIds.Strings[I];
      Store := FindCorpus(CorpusId);
      if Store = nil then
      begin
        Result := BuildToolError(AReq, ERR_CORPUS_NOT_FOUND,
          'Corpus not found: ' + CorpusId);
        // Free any created snippets arrays
        for K := 0 to MergedCount - 1 do
          MergedHits[K].Snippets.Free;
        Exit;
      end;

      if not IndexExists(CorpusId, DataRoot) then
      begin
        Result := BuildToolError(AReq, ERR_INDEX_MISSING,
          'No search index for corpus: ' + CorpusId +
          '. Indexes are built automatically at server startup. ' +
          'Restart the server or run: quran-tafseer-mcp index build --data <path>');
        for K := 0 to MergedCount - 1 do
          MergedHits[K].Snippets.Free;
        Exit;
      end;

      if SearchIndex(CorpusId, DataRoot, Query, Limit, Results) then
      begin
        for J := 0 to High(Results) do
          AddMergedHit(Results[J].Surah, Results[J].Ayah,
            Results[J].Score, CorpusId, Results[J].Snippet);
      end;
    end;
  end;

  // Sort by best score descending
  SortMergedByScore;

  // Build output
  HitsArr := TJSONArray.Create;
  for I := 0 to MergedCount - 1 do
  begin
    if I >= Limit then
    begin
      // Free unused snippet arrays
      MergedHits[I].Snippets.Free;
      Continue;
    end;
    HitObj := TJSONObject.Create;
    HitObj.Add('ref', 'Q ' + IntToStr(MergedHits[I].Surah) + ':' +
      IntToStr(MergedHits[I].Ayah));
    HitObj.Add('score', MergedHits[I].BestScore);
    HitObj.Add('snippets', MergedHits[I].Snippets);
    HitsArr.Add(HitObj);
  end;
  // Free any remaining beyond limit
  for I := Limit to MergedCount - 1 do
  begin
    // Already freed in loop above when I >= Limit
  end;

  ResObj := TJSONObject.Create;
  ResObj.Add('query', Query);
  ResObj.Add('hits', HitsArr);

  if IsTerminalFormat(AArgs) then
    Result := BuildToolResult(AReq,
      MakeTextContent(FormatSearchAsTerminal(ResObj)))
  else
    Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
  ResObj.Free;
end;

// ============================================================================
// quran.diff — word-level diff between translations
// ============================================================================

type
  TDiffOpKind = (dokEqual, dokDelete, dokInsert);
  TDiffOp = record
    Kind: TDiffOpKind;
    Text: String;
  end;
  TDiffOpArray = array of TDiffOp;
  TWordArray = array of String;

function IsWhitespace(C: Char): Boolean; inline;
begin
  Result := (C = ' ') or (C = #9) or (C = #10) or (C = #13);
end;

function Tokenize(const AText: String): TWordArray;
var
  I, Start, Count: Integer;
begin
  SetLength(Result, 0);
  Count := 0;
  I := 1;
  while I <= Length(AText) do
  begin
    // Skip whitespace (space, tab, newline, CR)
    while (I <= Length(AText)) and IsWhitespace(AText[I]) do
      Inc(I);
    if I > Length(AText) then
      Break;
    Start := I;
    while (I <= Length(AText)) and (not IsWhitespace(AText[I])) do
      Inc(I);
    Inc(Count);
    SetLength(Result, Count);
    Result[Count - 1] := Copy(AText, Start, I - Start);
  end;
end;

function ComputeWordDiff(const ATokensA, ATokensB: TWordArray): TDiffOpArray;
var
  M, N, I, J, OpCount: Integer;
  LCS: array of array of Integer;
  RawOps: array of TDiffOp;

  procedure AddRawOp(AKind: TDiffOpKind; const AText: String);
  begin
    if OpCount >= Length(RawOps) then
      SetLength(RawOps, OpCount + 64);
    RawOps[OpCount].Kind := AKind;
    RawOps[OpCount].Text := AText;
    Inc(OpCount);
  end;

  procedure Backtrack(AI, AJ: Integer);
  begin
    if (AI = 0) and (AJ = 0) then
      Exit;
    if (AI > 0) and (AJ > 0) and (ATokensA[AI - 1] = ATokensB[AJ - 1]) then
    begin
      Backtrack(AI - 1, AJ - 1);
      AddRawOp(dokEqual, ATokensA[AI - 1]);
    end
    else if (AJ > 0) and ((AI = 0) or (LCS[AI][AJ - 1] >= LCS[AI - 1][AJ])) then
    begin
      Backtrack(AI, AJ - 1);
      AddRawOp(dokInsert, ATokensB[AJ - 1]);
    end
    else if (AI > 0) then
    begin
      Backtrack(AI - 1, AJ);
      AddRawOp(dokDelete, ATokensA[AI - 1]);
    end;
  end;

var
  MergedCount: Integer;
begin
  M := Length(ATokensA);
  N := Length(ATokensB);

  // Build LCS table
  SetLength(LCS, M + 1, N + 1);
  for I := 0 to M do
    LCS[I][0] := 0;
  for J := 0 to N do
    LCS[0][J] := 0;

  for I := 1 to M do
    for J := 1 to N do
      if ATokensA[I - 1] = ATokensB[J - 1] then
        LCS[I][J] := LCS[I - 1][J - 1] + 1
      else if LCS[I - 1][J] >= LCS[I][J - 1] then
        LCS[I][J] := LCS[I - 1][J]
      else
        LCS[I][J] := LCS[I][J - 1];

  // Backtrack to get raw ops
  OpCount := 0;
  SetLength(RawOps, M + N);
  Backtrack(M, N);

  // Merge consecutive ops of the same kind
  MergedCount := 0;
  SetLength(Result, OpCount);
  for I := 0 to OpCount - 1 do
  begin
    if (MergedCount > 0) and (Result[MergedCount - 1].Kind = RawOps[I].Kind) then
      Result[MergedCount - 1].Text := Result[MergedCount - 1].Text + ' ' +
        RawOps[I].Text
    else
    begin
      Inc(MergedCount);
      if MergedCount > Length(Result) then
        SetLength(Result, MergedCount);
      Result[MergedCount - 1] := RawOps[I];
    end;
  end;
  SetLength(Result, MergedCount);
end;

function HandleDiff(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;
var
  Surah, Ayah, I, J: Integer;
  TransIds: TJSONArray;
  BaseId, CompId, BaseText, CompText: String;
  BaseTokens, CompTokens: TWordArray;
  Ops: TDiffOpArray;
  EqualCount, DeleteCount, InsertCount: Integer;
  Similarity: Double;
  ResObj, DiffEntry, StatsObj, OpObj: TJSONObject;
  DiffsArr, OpsArr: TJSONArray;
  Store: PVerseStore;
begin
  if AArgs = nil then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing arguments for quran.diff');
    Exit;
  end;

  Surah := AArgs.Get('surah', 0);
  Ayah := AArgs.Get('ayah', 0);

  if (Surah = 0) or (Ayah = 0) then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing required parameters: surah, ayah');
    Exit;
  end;

  // Validate reference
  if (Surah < 1) or (Surah > SURAH_COUNT) then
  begin
    Result := BuildToolError(AReq, ERR_VERSE_OUT_OF_RANGE,
      'Surah ' + IntToStr(Surah) + ' is out of range (1-' +
      IntToStr(SURAH_COUNT) + ').');
    Exit;
  end;

  if not IsValidReference(Surah, Ayah) then
  begin
    Result := BuildToolError(AReq, ERR_VERSE_OUT_OF_RANGE,
      'Ayah ' + IntToStr(Ayah) + ' is out of range for surah ' +
      IntToStr(Surah) + ' (max: ' + IntToStr(GetAyahCount(Surah)) + ').');
    Exit;
  end;

  // Parse translations array (required, min 2)
  TransIds := nil;
  if AArgs.IndexOfName('translations') >= 0 then
  begin
    if AArgs.Elements['translations'].JSONType = jtArray then
      TransIds := AArgs.Arrays['translations'];
  end;

  if (TransIds = nil) or (TransIds.Count < 2) then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'quran.diff requires "translations" array with at least 2 corpus IDs.');
    Exit;
  end;

  // Validate all corpus IDs exist
  for I := 0 to TransIds.Count - 1 do
  begin
    Store := FindCorpus(TransIds.Strings[I]);
    if Store = nil then
    begin
      Result := BuildToolError(AReq, ERR_CORPUS_NOT_FOUND,
        'Corpus not found: ' + TransIds.Strings[I]);
      Exit;
    end;
  end;

  // Base is the first translation
  BaseId := TransIds.Strings[0];
  BaseText := LookupVerse(BaseId, Surah, Ayah);
  BaseTokens := Tokenize(BaseText);

  // Build diffs: compare base against each subsequent translation
  DiffsArr := TJSONArray.Create;

  for I := 1 to TransIds.Count - 1 do
  begin
    CompId := TransIds.Strings[I];
    CompText := LookupVerse(CompId, Surah, Ayah);
    CompTokens := Tokenize(CompText);

    Ops := ComputeWordDiff(BaseTokens, CompTokens);

    // Count stats
    EqualCount := 0;
    DeleteCount := 0;
    InsertCount := 0;
    for J := 0 to High(Ops) do
    begin
      case Ops[J].Kind of
        dokEqual: Inc(EqualCount);
        dokDelete: Inc(DeleteCount);
        dokInsert: Inc(InsertCount);
      end;
    end;

    if (EqualCount + DeleteCount + InsertCount) > 0 then
      Similarity := EqualCount / (EqualCount + DeleteCount + InsertCount)
    else
      Similarity := 1.0;

    // Build ops array
    OpsArr := TJSONArray.Create;
    for J := 0 to High(Ops) do
    begin
      OpObj := TJSONObject.Create;
      case Ops[J].Kind of
        dokEqual:
        begin
          OpObj.Add('op', 'equal');
          OpObj.Add('text', Ops[J].Text);
        end;
        dokDelete:
        begin
          OpObj.Add('op', 'delete');
          OpObj.Add('text', Ops[J].Text);
        end;
        dokInsert:
        begin
          OpObj.Add('op', 'insert');
          OpObj.Add('text', Ops[J].Text);
        end;
      end;
      OpsArr.Add(OpObj);
    end;

    StatsObj := TJSONObject.Create;
    StatsObj.Add('equal', EqualCount);
    StatsObj.Add('deleted', DeleteCount);
    StatsObj.Add('inserted', InsertCount);
    StatsObj.Add('similarity', Round(Similarity * 100) / 100);

    DiffEntry := TJSONObject.Create;
    DiffEntry.Add('corpus_id', CompId);
    DiffEntry.Add('ops', OpsArr);
    DiffEntry.Add('stats', StatsObj);
    DiffsArr.Add(DiffEntry);
  end;

  ResObj := TJSONObject.Create;
  ResObj.Add('ref', 'Q ' + IntToStr(Surah) + ':' + IntToStr(Ayah));
  ResObj.Add('base', BaseId);
  ResObj.Add('diffs', DiffsArr);

  if IsTerminalFormat(AArgs) then
    Result := BuildToolResult(AReq,
      MakeTextContent(FormatDiffAsTerminal(ResObj)))
  else
    Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
  ResObj.Free;
end;

end.
