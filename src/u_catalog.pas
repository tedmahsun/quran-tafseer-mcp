unit u_catalog;

{$mode objfpc}{$H+}

interface

uses
  fpjson;

type
  TCatalogSource = record
    Provider: String;
    Url: String;
    Format: String;
    Checksum: String;
  end;

  TCatalogEntry = record
    Id: String;
    Title: String;
    Translator: String;
    Year: Integer;
    Sources: array of TCatalogSource;
    CanonicalSource: String;
    LicenseNote: String;
    Bundled: Boolean;
    BundledChecksum: String;
  end;
  PCatalogEntry = ^TCatalogEntry;

  TStringArray = array of String;

/// Load the catalog from a JSON file. Returns True on success.
function LoadCatalog(const AFilePath: String; out AError: String): Boolean;

/// Get the number of catalog entries (translations only).
function GetCatalogCount: Integer;

/// Get a catalog entry by index (0-based). Returns nil if out of range.
function GetCatalogEntryByIndex(AIndex: Integer): PCatalogEntry;

/// Find a catalog entry by ID. Returns nil if not found.
function FindCatalogEntry(const AId: String): PCatalogEntry;

/// Get the count of entries where Bundled = True.
function GetBundledCount: Integer;

/// Get IDs of all bundled entries.
function GetBundledIds: TStringArray;

/// Build a JSON array of catalog entries with install status.
/// Cross-references FindCorpus from u_corpus_store to set "installed" field.
/// If ALangFilter is non-empty, only entries matching that language prefix are returned.
function BuildCatalogListJson(const ALangFilter: String): TJSONArray;

/// Returns True if the catalog has been loaded.
function IsCatalogLoaded: Boolean;

/// Get the number of Arabic catalog entries.
function GetArabicCatalogCount: Integer;

/// Find an Arabic catalog entry by ID. Returns nil if not found.
function FindArabicEntry(const AId: String): PCatalogEntry;

/// Find the index of the preferred source for a catalog entry.
/// Matches CanonicalSource to a source's Provider. Falls back to index 0.
/// Returns -1 if the entry has no sources.
function FindPreferredSource(AEntry: PCatalogEntry): Integer;

implementation

uses
  SysUtils, Classes, jsonparser, u_log, u_corpus_store;

var
  CatalogEntries: array of TCatalogEntry;
  CatalogCount: Integer = 0;
  ArabicEntries: array of TCatalogEntry;
  ArabicCount: Integer = 0;
  CatalogLoaded: Boolean = False;

// ============================================================================
// PARSING HELPERS
// ============================================================================

procedure ParseSources(AArr: TJSONArray; out ASources: array of TCatalogSource);
var
  I: Integer;
  SrcObj: TJSONObject;
begin
  // Note: dynamic array must be set up by caller
  for I := 0 to AArr.Count - 1 do
  begin
    if not (AArr.Items[I] is TJSONObject) then
      Continue;
    SrcObj := TJSONObject(AArr.Items[I]);
    ASources[I].Provider := SrcObj.Get('provider', '');
    ASources[I].Url := SrcObj.Get('url', '');
    ASources[I].Format := SrcObj.Get('format', '');
    if (SrcObj.IndexOfName('checksum') >= 0) and
       (SrcObj.Elements['checksum'].JSONType <> jtNull) then
      ASources[I].Checksum := SrcObj.Get('checksum', '')
    else
      ASources[I].Checksum := '';
  end;
end;

procedure ParseEntry(AObj: TJSONObject; out AEntry: TCatalogEntry);
var
  SrcArr: TJSONArray;
begin
  AEntry.Id := AObj.Get('id', '');
  AEntry.Title := AObj.Get('title', '');
  AEntry.Translator := AObj.Get('translator', '');
  AEntry.Year := AObj.Get('year', 0);
  AEntry.CanonicalSource := AObj.Get('canonical_source', '');
  AEntry.LicenseNote := AObj.Get('license_note', '');
  AEntry.Bundled := AObj.Get('bundled', False);

  if (AObj.IndexOfName('bundled_checksum') >= 0) and
     (AObj.Elements['bundled_checksum'].JSONType <> jtNull) then
    AEntry.BundledChecksum := AObj.Get('bundled_checksum', '')
  else
    AEntry.BundledChecksum := '';

  // Parse sources array
  if (AObj.IndexOfName('sources') >= 0) and
     (AObj.Elements['sources'] is TJSONArray) then
  begin
    SrcArr := AObj.Arrays['sources'];
    SetLength(AEntry.Sources, SrcArr.Count);
    ParseSources(SrcArr, AEntry.Sources);
  end
  else
    SetLength(AEntry.Sources, 0);
end;

procedure ParseArabicEntry(AObj: TJSONObject; out AEntry: TCatalogEntry);
var
  SrcArr: TJSONArray;
begin
  AEntry.Id := AObj.Get('id', '');
  AEntry.Title := AObj.Get('title', '');
  AEntry.Translator := '';
  AEntry.Year := 0;
  AEntry.CanonicalSource := AObj.Get('canonical_source', '');
  AEntry.LicenseNote := AObj.Get('license_note', '');
  AEntry.Bundled := AObj.Get('bundled', False);

  if (AObj.IndexOfName('bundled_checksum') >= 0) and
     (AObj.Elements['bundled_checksum'].JSONType <> jtNull) then
    AEntry.BundledChecksum := AObj.Get('bundled_checksum', '')
  else
    AEntry.BundledChecksum := '';

  if (AObj.IndexOfName('sources') >= 0) and
     (AObj.Elements['sources'] is TJSONArray) then
  begin
    SrcArr := AObj.Arrays['sources'];
    SetLength(AEntry.Sources, SrcArr.Count);
    ParseSources(SrcArr, AEntry.Sources);
  end
  else
    SetLength(AEntry.Sources, 0);
end;

// ============================================================================
// PUBLIC FUNCTIONS
// ============================================================================

function LoadCatalog(const AFilePath: String; out AError: String): Boolean;
var
  FS: TFileStream;
  JsonStr: String;
  Data: TJSONData;
  Root: TJSONObject;
  TransArr, ArabArr: TJSONArray;
  I: Integer;
begin
  Result := False;
  AError := '';
  CatalogCount := 0;
  ArabicCount := 0;
  SetLength(CatalogEntries, 0);
  SetLength(ArabicEntries, 0);
  CatalogLoaded := False;

  if not FileExists(AFilePath) then
  begin
    AError := 'Catalog file not found: ' + AFilePath;
    Exit;
  end;

  // Read file
  JsonStr := '';
  try
    FS := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(JsonStr, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(JsonStr[1], FS.Size);
    finally
      FS.Free;
    end;
  except
    on E: Exception do
    begin
      AError := 'Error reading catalog: ' + E.Message;
      Exit;
    end;
  end;

  // Parse JSON
  Data := nil;
  try
    Data := GetJSON(JsonStr);
  except
    on E: Exception do
    begin
      AError := 'JSON parse error in catalog: ' + E.Message;
      Exit;
    end;
  end;

  if not (Data is TJSONObject) then
  begin
    AError := 'Catalog root is not a JSON object';
    Data.Free;
    Exit;
  end;

  Root := TJSONObject(Data);
  try
    // Parse translations array
    if (Root.IndexOfName('translations') < 0) or
       not (Root.Elements['translations'] is TJSONArray) then
    begin
      AError := 'Catalog missing "translations" array';
      Exit;
    end;

    TransArr := Root.Arrays['translations'];
    SetLength(CatalogEntries, TransArr.Count);
    CatalogCount := 0;

    for I := 0 to TransArr.Count - 1 do
    begin
      if not (TransArr.Items[I] is TJSONObject) then
        Continue;
      ParseEntry(TJSONObject(TransArr.Items[I]), CatalogEntries[CatalogCount]);
      if CatalogEntries[CatalogCount].Id <> '' then
        Inc(CatalogCount);
    end;

    SetLength(CatalogEntries, CatalogCount);

    // Parse Arabic array (optional)
    if (Root.IndexOfName('arabic') >= 0) and
       (Root.Elements['arabic'] is TJSONArray) then
    begin
      ArabArr := Root.Arrays['arabic'];
      SetLength(ArabicEntries, ArabArr.Count);
      ArabicCount := 0;

      for I := 0 to ArabArr.Count - 1 do
      begin
        if not (ArabArr.Items[I] is TJSONObject) then
          Continue;
        ParseArabicEntry(TJSONObject(ArabArr.Items[I]),
          ArabicEntries[ArabicCount]);
        if ArabicEntries[ArabicCount].Id <> '' then
          Inc(ArabicCount);
      end;

      SetLength(ArabicEntries, ArabicCount);
    end;

    CatalogLoaded := True;
    LogInfo('Catalog loaded: ' + IntToStr(CatalogCount) + ' translations, ' +
      IntToStr(ArabicCount) + ' arabic');
    Result := True;
  finally
    Root.Free;
  end;
end;

function GetCatalogCount: Integer;
begin
  Result := CatalogCount;
end;

function GetCatalogEntryByIndex(AIndex: Integer): PCatalogEntry;
begin
  if (AIndex >= 0) and (AIndex < CatalogCount) then
    Result := @CatalogEntries[AIndex]
  else
    Result := nil;
end;

function FindCatalogEntry(const AId: String): PCatalogEntry;
var
  I: Integer;
begin
  Result := nil;
  // Search translations
  for I := 0 to CatalogCount - 1 do
  begin
    if CatalogEntries[I].Id = AId then
    begin
      Result := @CatalogEntries[I];
      Exit;
    end;
  end;
  // Search Arabic entries
  for I := 0 to ArabicCount - 1 do
  begin
    if ArabicEntries[I].Id = AId then
    begin
      Result := @ArabicEntries[I];
      Exit;
    end;
  end;
end;

function GetBundledCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to CatalogCount - 1 do
  begin
    if CatalogEntries[I].Bundled then
      Inc(Result);
  end;
  for I := 0 to ArabicCount - 1 do
  begin
    if ArabicEntries[I].Bundled then
      Inc(Result);
  end;
end;

function GetBundledIds: TStringArray;
var
  I, Count: Integer;
begin
  Result := nil;
  Count := 0;
  SetLength(Result, CatalogCount + ArabicCount);
  for I := 0 to CatalogCount - 1 do
  begin
    if CatalogEntries[I].Bundled then
    begin
      Result[Count] := CatalogEntries[I].Id;
      Inc(Count);
    end;
  end;
  for I := 0 to ArabicCount - 1 do
  begin
    if ArabicEntries[I].Bundled then
    begin
      Result[Count] := ArabicEntries[I].Id;
      Inc(Count);
    end;
  end;
  SetLength(Result, Count);
end;

function BuildCatalogListJson(const ALangFilter: String): TJSONArray;
var
  I, J: Integer;
  Entry: PCatalogEntry;
  Obj, SrcObj: TJSONObject;
  SrcArr: TJSONArray;
  Installed: Boolean;
begin
  Result := TJSONArray.Create;
  for I := 0 to CatalogCount - 1 do
  begin
    Entry := @CatalogEntries[I];

    // Apply language filter (check if ID starts with the lang prefix)
    if (ALangFilter <> '') and (Pos(ALangFilter + '.', Entry^.Id) <> 1) then
      Continue;

    // Check install status via corpus store
    Installed := (FindCorpus(Entry^.Id) <> nil);

    Obj := TJSONObject.Create;
    Obj.Add('id', Entry^.Id);
    Obj.Add('title', Entry^.Title);
    Obj.Add('translator', Entry^.Translator);
    if Entry^.Year > 0 then
      Obj.Add('year', Entry^.Year);
    Obj.Add('license_note', Entry^.LicenseNote);
    Obj.Add('bundled', Entry^.Bundled);
    Obj.Add('installed', Installed);

    // Sources
    SrcArr := TJSONArray.Create;
    for J := 0 to High(Entry^.Sources) do
    begin
      SrcObj := TJSONObject.Create;
      SrcObj.Add('provider', Entry^.Sources[J].Provider);
      SrcObj.Add('format', Entry^.Sources[J].Format);
      SrcArr.Add(SrcObj);
    end;
    Obj.Add('sources', SrcArr);

    Result.Add(Obj);
  end;
end;

function IsCatalogLoaded: Boolean;
begin
  Result := CatalogLoaded;
end;

function GetArabicCatalogCount: Integer;
begin
  Result := ArabicCount;
end;

function FindArabicEntry(const AId: String): PCatalogEntry;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to ArabicCount - 1 do
  begin
    if ArabicEntries[I].Id = AId then
    begin
      Result := @ArabicEntries[I];
      Exit;
    end;
  end;
end;

function FindPreferredSource(AEntry: PCatalogEntry): Integer;
var
  I: Integer;
begin
  Result := -1;
  if Length(AEntry^.Sources) = 0 then
    Exit;

  // Match canonical_source to a source's provider
  for I := 0 to High(AEntry^.Sources) do
  begin
    if AEntry^.Sources[I].Provider = AEntry^.CanonicalSource then
    begin
      Result := I;
      Exit;
    end;
  end;

  // Fallback: first source
  Result := 0;
end;

end.
