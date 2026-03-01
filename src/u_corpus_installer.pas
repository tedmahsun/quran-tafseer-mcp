unit u_corpus_installer;

{$mode objfpc}{$H+}

interface

uses
  Classes, u_catalog;

type
  TInstallResult = record
    CorpusId: String;
    Success: Boolean;
    Skipped: Boolean;
    ErrorMsg: String;
  end;

  TInstallReport = record
    Installed: array of String;
    Skipped: array of String;
    Errors: array of TInstallResult;
  end;

/// Install all bundled corpora from ABundledPath into ADataRoot.
/// ABundledPath should point to the directory containing corpus subdirs
/// (e.g., <repo>/bundled/quran/).
/// ADataRoot is the user data root (corpora go into <ADataRoot>/corpora/quran/).
/// Idempotent: skips corpora that already exist at the destination.
function InstallBundledCorpora(const ABundledPath, ADataRoot: String): TInstallReport;

/// Install a single corpus from ASrcDir to ADestDir.
/// Copies manifest.json and original.tsv (or other data file).
/// Returns True on success.
function InstallSingleCorpus(const ASrcDir, ADestDir: String;
  out AError: String): Boolean;

/// Convert quran-api JSON ({"quran":[{"chapter":N,"verse":N,"text":"..."}]})
/// to TSV (surah<TAB>ayah<TAB>text). Returns TSV string.
function ConvertQuranApiJsonToTsv(AData: TStream;
  out ATsv: String; out AError: String): Boolean;

/// Convert Tanzil pipe format (surah|ayah|text) to TSV.
/// Strips comment lines (#) and BOM.
function ConvertTanzilPipeToTsv(AData: TStream;
  out ATsv: String; out AError: String): Boolean;

/// Install a corpus from downloaded data. Converts to TSV, writes original.tsv
/// and generates manifest.json with origin:"downloaded".
function InstallDownloadedCorpus(AData: TStream; ACatalogEntry: PCatalogEntry;
  const ASourceUrl, ASourceFormat, ADataRoot: String;
  out AError: String): Boolean;

/// Download and install a single catalog entry. Finds preferred source,
/// downloads, converts, installs. Idempotent: skips if already installed.
function DownloadAndInstallCatalogEntry(ACatalogEntry: PCatalogEntry;
  const ADataRoot: String; out ASkipped: Boolean;
  out AError: String): Boolean;

/// Compute SHA-256 checksum of a file, returning 'sha256:<hex>'.
/// Returns empty string on error.
function ComputeFileChecksum(const AFilePath: String): String;

/// Install a local corpus file into the data root.
/// Validates the file, copies it, generates manifest, returns success.
function InstallLocalCorpus(const AFilePath, AId, AKind, ALang,
  AFormat, ATitle, AAuthor, ADataRoot: String;
  out AError: String): Boolean;

implementation

uses
  SysUtils, fpjson, jsonparser, u_corpus_manifest, u_log,
  u_downloader, u_corpus_store, u_corpus_reader;

// ============================================================================
// FILE HELPERS
// ============================================================================

/// Simple stream-based file copy. No LCL dependency.
function CopyFileSimple(const ASrc, ADest: String): Boolean;
var
  SrcStream, DestStream: TFileStream;
begin
  Result := False;
  try
    SrcStream := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
    try
      DestStream := TFileStream.Create(ADest, fmCreate);
      try
        DestStream.CopyFrom(SrcStream, SrcStream.Size);
        Result := True;
      finally
        DestStream.Free;
      end;
    finally
      SrcStream.Free;
    end;
  except
    on E: Exception do
      LogError('CopyFileSimple failed: ' + ASrc + ' -> ' + ADest +
        ': ' + E.Message);
  end;
end;

// ============================================================================
// BUNDLED INSTALL (existing)
// ============================================================================

function InstallSingleCorpus(const ASrcDir, ADestDir: String;
  out AError: String): Boolean;
var
  Manifest: TCorpusManifest;
  SrcFile, DestFile, DataFileName: String;
  SR: TSearchRec;
begin
  Result := False;
  AError := '';

  // Validate source has a manifest
  if not LoadManifest(ASrcDir, Manifest, AError) then
  begin
    AError := 'Invalid source corpus: ' + AError;
    Exit;
  end;

  // Create destination directory
  if not ForceDirectories(ADestDir) then
  begin
    AError := 'Cannot create directory: ' + ADestDir;
    Exit;
  end;

  // Copy manifest.json
  SrcFile := IncludeTrailingPathDelimiter(ASrcDir) + 'manifest.json';
  DestFile := IncludeTrailingPathDelimiter(ADestDir) + 'manifest.json';
  if not CopyFileSimple(SrcFile, DestFile) then
  begin
    AError := 'Failed to copy manifest.json';
    Exit;
  end;

  // Copy data files (original.tsv, original.jsonl, etc.)
  if FindFirst(IncludeTrailingPathDelimiter(ASrcDir) + 'original.*',
    faAnyFile and not faDirectory, SR) = 0 then
  begin
    try
      repeat
        DataFileName := SR.Name;
        SrcFile := IncludeTrailingPathDelimiter(ASrcDir) + DataFileName;
        DestFile := IncludeTrailingPathDelimiter(ADestDir) + DataFileName;
        if not CopyFileSimple(SrcFile, DestFile) then
        begin
          AError := 'Failed to copy ' + DataFileName;
          Exit;
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

  LogInfo('Installed corpus: ' + Manifest.Id + ' -> ' + ADestDir);
  Result := True;
end;

function InstallBundledCorpora(const ABundledPath, ADataRoot: String): TInstallReport;
var
  SR: TSearchRec;
  SrcDir, DestBase, DestDir, ErrMsg: String;
  InstalledCount, SkippedCount, ErrorCount: Integer;
  IR: TInstallResult;
begin
  Result := Default(TInstallReport);
  InstalledCount := 0;
  SkippedCount := 0;
  ErrorCount := 0;
  SetLength(Result.Installed, 0);
  SetLength(Result.Skipped, 0);
  SetLength(Result.Errors, 0);

  DestBase := IncludeTrailingPathDelimiter(ADataRoot) + 'corpora' +
    PathDelim + 'quran';

  if not DirectoryExists(ABundledPath) then
  begin
    LogWarn('Bundled path does not exist: ' + ABundledPath);
    Exit;
  end;

  LogInfo('Installing bundled corpora from: ' + ABundledPath);

  // Ensure destination base exists
  if not ForceDirectories(DestBase) then
  begin
    LogError('Cannot create corpora directory: ' + DestBase);
    Exit;
  end;

  if FindFirst(IncludeTrailingPathDelimiter(ABundledPath) + '*',
    faDirectory, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        if (SR.Attr and faDirectory) = 0 then
          Continue;

        SrcDir := IncludeTrailingPathDelimiter(ABundledPath) + SR.Name;
        DestDir := IncludeTrailingPathDelimiter(DestBase) + SR.Name;

        // Idempotency: skip if manifest.json already exists at destination
        if FileExists(IncludeTrailingPathDelimiter(DestDir) + 'manifest.json') then
        begin
          LogDebug('Skipping (already installed): ' + SR.Name);
          Inc(SkippedCount);
          SetLength(Result.Skipped, SkippedCount);
          Result.Skipped[SkippedCount - 1] := SR.Name;
          Continue;
        end;

        ErrMsg := '';
        if InstallSingleCorpus(SrcDir, DestDir, ErrMsg) then
        begin
          Inc(InstalledCount);
          SetLength(Result.Installed, InstalledCount);
          Result.Installed[InstalledCount - 1] := SR.Name;
        end
        else
        begin
          IR.CorpusId := SR.Name;
          IR.Success := False;
          IR.Skipped := False;
          IR.ErrorMsg := ErrMsg;
          Inc(ErrorCount);
          SetLength(Result.Errors, ErrorCount);
          Result.Errors[ErrorCount - 1] := IR;
          LogError('Failed to install ' + SR.Name + ': ' + ErrMsg);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

  LogInfo('Bundled install complete: ' + IntToStr(InstalledCount) +
    ' installed, ' + IntToStr(SkippedCount) + ' skipped, ' +
    IntToStr(ErrorCount) + ' errors');
end;

// ============================================================================
// FORMAT CONVERTERS
// ============================================================================

function ConvertQuranApiJsonToTsv(AData: TStream;
  out ATsv: String; out AError: String): Boolean;
var
  JsonStr: String;
  Data: TJSONData;
  Root: TJSONObject;
  Arr: TJSONArray;
  Item: TJSONObject;
  I, Chapter, Verse: Integer;
  Text: String;
  SB: TStringList;
begin
  Result := False;
  ATsv := '';
  AError := '';

  // Read stream to string
  AData.Position := 0;
  SetLength(JsonStr, AData.Size);
  if AData.Size > 0 then
    AData.Read(JsonStr[1], AData.Size);

  // Strip UTF-8 BOM if present
  if (Length(JsonStr) >= 3) and (JsonStr[1] = #$EF) and
     (JsonStr[2] = #$BB) and (JsonStr[3] = #$BF) then
    Delete(JsonStr, 1, 3);

  // Parse JSON
  Data := nil;
  try
    Data := GetJSON(JsonStr);
  except
    on E: Exception do
    begin
      AError := 'JSON parse error: ' + E.Message;
      Exit;
    end;
  end;

  if not (Data is TJSONObject) then
  begin
    AError := 'Root is not a JSON object';
    Data.Free;
    Exit;
  end;

  Root := TJSONObject(Data);
  try
    if (Root.IndexOfName('quran') < 0) or
       not (Root.Elements['quran'] is TJSONArray) then
    begin
      AError := 'Missing "quran" array in JSON';
      Exit;
    end;

    Arr := Root.Arrays['quran'];
    SB := TStringList.Create;
    try
      SB.LineBreak := #10;
      for I := 0 to Arr.Count - 1 do
      begin
        if not (Arr.Items[I] is TJSONObject) then
          Continue;
        Item := TJSONObject(Arr.Items[I]);

        Chapter := Item.Get('chapter', 0);
        Verse := Item.Get('verse', 0);
        Text := Item.Get('text', '');

        if (Chapter < 1) or (Verse < 1) then
          Continue;

        SB.Add(IntToStr(Chapter) + #9 + IntToStr(Verse) + #9 + Text);
      end;
      ATsv := SB.Text;
      Result := True;
    finally
      SB.Free;
    end;
  finally
    Root.Free;
  end;
end;

function ConvertTanzilPipeToTsv(AData: TStream;
  out ATsv: String; out AError: String): Boolean;
var
  RawStr, Line: String;
  Lines, OutLines: TStringList;
  I, Pipe1, Pipe2: Integer;
  Surah, Ayah, Text: String;
begin
  Result := False;
  ATsv := '';
  AError := '';

  // Read stream to string
  AData.Position := 0;
  SetLength(RawStr, AData.Size);
  if AData.Size > 0 then
    AData.Read(RawStr[1], AData.Size);

  // Strip UTF-8 BOM
  if (Length(RawStr) >= 3) and (RawStr[1] = #$EF) and
     (RawStr[2] = #$BB) and (RawStr[3] = #$BF) then
    Delete(RawStr, 1, 3);

  Lines := TStringList.Create;
  OutLines := TStringList.Create;
  try
    Lines.Text := RawStr;
    OutLines.LineBreak := #10;

    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or (Line[1] = '#') then
        Continue;

      // Parse surah|ayah|text
      Pipe1 := Pos('|', Line);
      if Pipe1 = 0 then
        Continue;

      Pipe2 := Pos('|', Copy(Line, Pipe1 + 1, Length(Line)));
      if Pipe2 = 0 then
        Continue;
      Pipe2 := Pipe1 + Pipe2;

      Surah := Copy(Line, 1, Pipe1 - 1);
      Ayah := Copy(Line, Pipe1 + 1, Pipe2 - Pipe1 - 1);
      Text := Copy(Line, Pipe2 + 1, Length(Line));

      if (StrToIntDef(Surah, 0) < 1) or (StrToIntDef(Ayah, 0) < 1) then
        Continue;

      OutLines.Add(Surah + #9 + Ayah + #9 + Text);
    end;

    ATsv := OutLines.Text;
    Result := True;
  finally
    Lines.Free;
    OutLines.Free;
  end;
end;

// ============================================================================
// DOWNLOADED CORPUS INSTALL
// ============================================================================

function ExtractLangFromId(const AId: String): String;
var
  DotPos: Integer;
begin
  DotPos := Pos('.', AId);
  if DotPos > 0 then
    Result := Copy(AId, 1, DotPos - 1)
  else
    Result := '';
end;

function InstallDownloadedCorpus(AData: TStream; ACatalogEntry: PCatalogEntry;
  const ASourceUrl, ASourceFormat, ADataRoot: String;
  out AError: String): Boolean;
var
  TsvContent: String;
  DestBase, DestDir, TsvPath, ManifestPath: String;
  TsvStream: TStringStream;
  Checksum, KindStr, Lang, Now_: String;
  ManifestObj: TJSONObject;
  F: TextFile;
begin
  Result := False;
  AError := '';

  // Convert to TSV based on source format
  if ASourceFormat = 'json_chapter_verse_text' then
  begin
    if not ConvertQuranApiJsonToTsv(AData, TsvContent, AError) then
    begin
      AError := 'Format conversion failed: ' + AError;
      Exit;
    end;
  end
  else if ASourceFormat = 'tsv_pipe_surah_ayah_text' then
  begin
    if not ConvertTanzilPipeToTsv(AData, TsvContent, AError) then
    begin
      AError := 'Format conversion failed: ' + AError;
      Exit;
    end;
  end
  else
  begin
    AError := 'Unsupported source format: ' + ASourceFormat;
    Exit;
  end;

  if Length(TsvContent) = 0 then
  begin
    AError := 'Conversion produced empty TSV';
    Exit;
  end;

  // Create destination directory
  DestBase := IncludeTrailingPathDelimiter(ADataRoot) + 'corpora' +
    PathDelim + 'quran';
  DestDir := IncludeTrailingPathDelimiter(DestBase) + ACatalogEntry^.Id;

  if not ForceDirectories(DestDir) then
  begin
    AError := 'Cannot create directory: ' + DestDir;
    Exit;
  end;

  // Write original.tsv
  TsvPath := IncludeTrailingPathDelimiter(DestDir) + 'original.tsv';
  AssignFile(F, TsvPath);
  try
    Rewrite(F);
    try
      Write(F, TsvContent);
    finally
      CloseFile(F);
    end;
  except
    on E: Exception do
    begin
      AError := 'Failed to write TSV: ' + E.Message;
      Exit;
    end;
  end;

  // Compute SHA-256 of the written TSV
  TsvStream := TStringStream.Create(TsvContent);
  try
    Checksum := 'sha256:' + ComputeSha256Hex(TsvStream);
  finally
    TsvStream.Free;
  end;

  // Determine kind and language
  Lang := ExtractLangFromId(ACatalogEntry^.Id);
  if Lang = 'ar' then
    KindStr := 'quran_arabic'
  else
    KindStr := 'translation';

  Now_ := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', Now);

  // Generate manifest.json
  ManifestObj := TJSONObject.Create;
  try
    ManifestObj.Add('id', ACatalogEntry^.Id);
    ManifestObj.Add('kind', KindStr);
    ManifestObj.Add('language', Lang);
    ManifestObj.Add('title', ACatalogEntry^.Title);
    if ACatalogEntry^.Translator <> '' then
      ManifestObj.Add('translator', ACatalogEntry^.Translator);
    ManifestObj.Add('source', ACatalogEntry^.CanonicalSource);
    ManifestObj.Add('license_note', ACatalogEntry^.LicenseNote);
    ManifestObj.Add('format', 'tsv_surah_ayah_text');
    ManifestObj.Add('checksum', Checksum);
    ManifestObj.Add('origin', 'downloaded');
    ManifestObj.Add('download_source', ASourceUrl);
    ManifestObj.Add('download_date', Now_);
    ManifestObj.Add('created_at', Now_);

    ManifestPath := IncludeTrailingPathDelimiter(DestDir) + 'manifest.json';
    AssignFile(F, ManifestPath);
    try
      Rewrite(F);
      try
        Write(F, ManifestObj.FormatJSON);
      finally
        CloseFile(F);
      end;
    except
      on E: Exception do
      begin
        AError := 'Failed to write manifest: ' + E.Message;
        Exit;
      end;
    end;
  finally
    ManifestObj.Free;
  end;

  LogInfo('Installed downloaded corpus: ' + ACatalogEntry^.Id + ' -> ' + DestDir);
  Result := True;
end;

// ============================================================================
// FILE CHECKSUM
// ============================================================================

function ComputeFileChecksum(const AFilePath: String): String;
var
  FS: TFileStream;
begin
  Result := '';
  try
    FS := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
    try
      Result := 'sha256:' + ComputeSha256Hex(FS);
    finally
      FS.Free;
    end;
  except
    on E: Exception do
      LogError('ComputeFileChecksum failed for ' + AFilePath + ': ' + E.Message);
  end;
end;

// ============================================================================
// LOCAL CORPUS INSTALL
// ============================================================================

function InstallLocalCorpus(const AFilePath, AId, AKind, ALang,
  AFormat, ATitle, AAuthor, ADataRoot: String;
  out AError: String): Boolean;
var
  DestBase, DestDir, DestFile, ManifestPath, Ext, Checksum, Now_: String;
  ManifestObj: TJSONObject;
  TestStore: TVerseStore;
  F: TextFile;
begin
  Result := False;
  AError := '';

  // Determine file extension from format
  if AFormat = 'tsv_surah_ayah_text' then
    Ext := '.tsv'
  else if AFormat = 'jsonl_surah_ayah_text' then
    Ext := '.jsonl'
  else
  begin
    AError := 'Unsupported format: ' + AFormat;
    Exit;
  end;

  // Validate source file exists
  if not FileExists(AFilePath) then
  begin
    AError := 'File not found: ' + AFilePath;
    Exit;
  end;

  // Trial-load the file to validate it parses correctly
  SetLength(TestStore.Verses, VERSE_ARRAY_SIZE);
  TestStore.VerseCount := 0;
  TestStore.Loaded := False;

  if AFormat = 'tsv_surah_ayah_text' then
  begin
    if not u_corpus_reader.LoadTsvFile(AFilePath, TestStore, AError) then
    begin
      AError := 'File validation failed: ' + AError;
      Exit;
    end;
  end
  else if AFormat = 'jsonl_surah_ayah_text' then
  begin
    if not u_corpus_reader.LoadJsonlFile(AFilePath, TestStore, AError) then
    begin
      AError := 'File validation failed: ' + AError;
      Exit;
    end;
  end;

  if TestStore.VerseCount = 0 then
  begin
    AError := 'File contains no valid verses';
    Exit;
  end;

  // Create destination directory
  DestBase := IncludeTrailingPathDelimiter(ADataRoot) + 'corpora' +
    PathDelim + 'quran';
  DestDir := IncludeTrailingPathDelimiter(DestBase) + AId;

  if not ForceDirectories(DestDir) then
  begin
    AError := 'Cannot create directory: ' + DestDir;
    Exit;
  end;

  // Copy file to destination
  DestFile := IncludeTrailingPathDelimiter(DestDir) + 'original' + Ext;
  if not CopyFileSimple(AFilePath, DestFile) then
  begin
    AError := 'Failed to copy file to: ' + DestFile;
    Exit;
  end;

  // Compute checksum of the installed file
  Checksum := ComputeFileChecksum(DestFile);
  if Checksum = '' then
  begin
    AError := 'Failed to compute checksum';
    Exit;
  end;

  Now_ := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', Now);

  // Generate manifest.json
  ManifestObj := TJSONObject.Create;
  try
    ManifestObj.Add('id', AId);
    ManifestObj.Add('kind', AKind);
    ManifestObj.Add('language', ALang);
    ManifestObj.Add('title', ATitle);
    if AAuthor <> '' then
      ManifestObj.Add('translator', AAuthor);
    ManifestObj.Add('format', AFormat);
    ManifestObj.Add('checksum', Checksum);
    ManifestObj.Add('origin', 'manual_import');
    ManifestObj.Add('created_at', Now_);

    ManifestPath := IncludeTrailingPathDelimiter(DestDir) + 'manifest.json';
    AssignFile(F, ManifestPath);
    try
      Rewrite(F);
      try
        Write(F, ManifestObj.FormatJSON);
      finally
        CloseFile(F);
      end;
    except
      on E: Exception do
      begin
        AError := 'Failed to write manifest: ' + E.Message;
        Exit;
      end;
    end;
  finally
    ManifestObj.Free;
  end;

  LogInfo('Installed local corpus: ' + AId + ' (' +
    IntToStr(TestStore.VerseCount) + ' verses) -> ' + DestDir);
  Result := True;
end;

function DownloadAndInstallCatalogEntry(ACatalogEntry: PCatalogEntry;
  const ADataRoot: String; out ASkipped: Boolean;
  out AError: String): Boolean;
var
  DestDir, ManifestPath: String;
  SrcIdx: Integer;
  SrcUrl, SrcFormat, SrcChecksum: String;
  Data: TMemoryStream;
begin
  Result := False;
  ASkipped := False;
  AError := '';

  // Idempotent: skip if already installed
  DestDir := IncludeTrailingPathDelimiter(ADataRoot) + 'corpora' +
    PathDelim + 'quran' + PathDelim + ACatalogEntry^.Id;
  ManifestPath := IncludeTrailingPathDelimiter(DestDir) + 'manifest.json';
  if FileExists(ManifestPath) then
  begin
    LogDebug('Already installed, skipping: ' + ACatalogEntry^.Id);
    ASkipped := True;
    Result := True;
    Exit;
  end;

  // Find preferred source
  SrcIdx := FindPreferredSource(ACatalogEntry);
  if SrcIdx < 0 then
  begin
    AError := 'No download sources available for ' + ACatalogEntry^.Id;
    Exit;
  end;

  SrcUrl := ACatalogEntry^.Sources[SrcIdx].Url;
  SrcFormat := ACatalogEntry^.Sources[SrcIdx].Format;
  SrcChecksum := ACatalogEntry^.Sources[SrcIdx].Checksum;

  // Download (with optional checksum verification)
  Data := nil;
  if not DownloadAndVerify(SrcUrl, SrcChecksum, Data, AError) then
    Exit;

  try
    // Install (convert + write)
    if not InstallDownloadedCorpus(Data, ACatalogEntry, SrcUrl, SrcFormat,
      ADataRoot, AError) then
      Exit;
  finally
    Data.Free;
  end;

  Result := True;
end;

end.
