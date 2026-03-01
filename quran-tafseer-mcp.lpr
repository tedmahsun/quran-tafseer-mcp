program QuranTafseerMcp;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes,
  u_log,
  u_jsonrpc,
  u_mcp,
  u_quran_metadata,
  u_corpus_manifest,
  u_corpus_reader,
  u_corpus_store,
  u_catalog,
  u_corpus_installer,
  u_downloader,
  u_index_sqlite;

procedure PrintUsage;
begin
  WriteLn(StdErr, 'Usage: quran-tafseer-mcp <command> [options]');
  WriteLn(StdErr, '');
  WriteLn(StdErr, 'Commands:');
  WriteLn(StdErr, '  mcp             Run as MCP server over stdio');
  WriteLn(StdErr, '  init            First-run setup (install bundled + download)');
  WriteLn(StdErr, '  corpus list     List installed corpora');
  WriteLn(StdErr, '  corpus validate Validate corpus integrity');
  WriteLn(StdErr, '  corpus add      Import a local corpus file');
  WriteLn(StdErr, '  index build     Build search indexes for corpora');
  WriteLn(StdErr, '');
  WriteLn(StdErr, 'Options:');
  WriteLn(StdErr, '  --data <path>          Data root directory (default: platform-specific)');
  WriteLn(StdErr, '                         Windows: %LOCALAPPDATA%\quran-tafseer-mcp');
  WriteLn(StdErr, '                         Linux/macOS: $XDG_DATA_HOME/quran-tafseer-mcp');
  WriteLn(StdErr, '  --bundled-only         Init: install bundled corpora only (no network)');
  WriteLn(StdErr, '  --all                  Init: install bundled + download all translations + Arabic variants');
  WriteLn(StdErr, '  --bundled-path <path>  Override bundled corpora directory');
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

function GetDefaultDataRoot: String;
begin
  {$IFDEF MSWINDOWS}
  Result := GetEnvironmentVariable('LOCALAPPDATA');
  if Result = '' then
    Result := GetEnvironmentVariable('APPDATA');
  {$ELSE}
  Result := GetEnvironmentVariable('XDG_DATA_HOME');
  if Result = '' then
    Result := GetEnvironmentVariable('HOME') + PathDelim + '.local' + PathDelim + 'share';
  {$ENDIF}
  Result := Result + PathDelim + 'quran-tafseer-mcp';
end;

procedure RunInitBundledOnly(const ADataRoot, ABundledDir: String);
var
  Report: TInstallReport;
  I: Integer;
begin
  if not DirectoryExists(ABundledDir) then
  begin
    WriteLn(StdErr, 'Error: Bundled directory not found: ' + ABundledDir);
    Halt(1);
  end;

  WriteLn(StdErr, 'Installing bundled corpora from: ' + ABundledDir);
  WriteLn(StdErr, 'Data root: ' + ADataRoot);

  Report := InstallBundledCorpora(ABundledDir, ADataRoot);

  WriteLn(StdErr, '');
  WriteLn(StdErr, 'Installed: ', Length(Report.Installed));
  for I := 0 to High(Report.Installed) do
    WriteLn(StdErr, '  + ', Report.Installed[I]);

  WriteLn(StdErr, 'Skipped:   ', Length(Report.Skipped));
  for I := 0 to High(Report.Skipped) do
    WriteLn(StdErr, '  = ', Report.Skipped[I]);

  if Length(Report.Errors) > 0 then
  begin
    WriteLn(StdErr, 'Errors:    ', Length(Report.Errors));
    for I := 0 to High(Report.Errors) do
      WriteLn(StdErr, '  ! ', Report.Errors[I].CorpusId, ': ',
        Report.Errors[I].ErrorMsg);
    Halt(1);
  end;

  WriteLn(StdErr, '');
  WriteLn(StdErr, 'Done.');
end;

procedure RunInitFull(const ADataRoot, ABundledDir: String; ADownloadAll: Boolean);
var
  Report: TInstallReport;
  CatalogPath, CatErr, ErrMsg: String;
  I: Integer;
  Entry: PCatalogEntry;
  Skipped: Boolean;
  DownloadFailures: Integer;
begin
  DownloadFailures := 0;

  // Step 1: Install bundled corpora
  if DirectoryExists(ABundledDir) then
  begin
    WriteLn(StdErr, 'Step 1: Installing bundled corpora...');
    Report := InstallBundledCorpora(ABundledDir, ADataRoot);
    WriteLn(StdErr, '  Installed: ', Length(Report.Installed),
      ', Skipped: ', Length(Report.Skipped),
      ', Errors: ', Length(Report.Errors));
  end
  else
    WriteLn(StdErr, 'Step 1: Bundled directory not found, skipping.');

  // Step 2: Load catalog
  CatalogPath := ExtractFilePath(ParamStr(0)) + 'catalog' +
    PathDelim + 'translations.json';
  CatErr := '';
  if FileExists(CatalogPath) then
  begin
    if LoadCatalog(CatalogPath, CatErr) then
      WriteLn(StdErr, 'Step 2: Catalog loaded (' +
        IntToStr(GetCatalogCount) + ' translations, ' +
        IntToStr(GetArabicCatalogCount) + ' arabic)')
    else
    begin
      WriteLn(StdErr, 'Step 2: Failed to load catalog: ' + CatErr);
      WriteLn(StdErr, 'Cannot proceed with downloads.');
      if DownloadFailures > 0 then
        Halt(1);
      Exit;
    end;
  end
  else
  begin
    WriteLn(StdErr, 'Step 2: Catalog not found at: ' + CatalogPath);
    WriteLn(StdErr, 'Cannot proceed with downloads.');
    Halt(1);
  end;

  // Step 3: If --all, download all non-installed catalog translations + Arabic
  if ADownloadAll then
  begin
    WriteLn(StdErr, 'Step 3: Downloading all catalog translations...');
    for I := 0 to GetCatalogCount - 1 do
    begin
      Entry := GetCatalogEntryByIndex(I);
      if Entry = nil then
        Continue;

      Skipped := False;
      ErrMsg := '';
      if DownloadAndInstallCatalogEntry(Entry, ADataRoot, Skipped, ErrMsg) then
      begin
        if Skipped then
          WriteLn(StdErr, '  = ', Entry^.Id, ' (already installed)')
        else
          WriteLn(StdErr, '  + ', Entry^.Id);
      end
      else
      begin
        WriteLn(StdErr, '  ! ', Entry^.Id, ': ', ErrMsg);
        Inc(DownloadFailures);
      end;
    end;

    // Also download non-bundled Arabic variants
    WriteLn(StdErr, 'Downloading non-bundled Arabic corpora...');
    Entry := FindArabicEntry('ar.simple');
    if Entry <> nil then
    begin
      Skipped := False;
      ErrMsg := '';
      if DownloadAndInstallCatalogEntry(Entry, ADataRoot, Skipped, ErrMsg) then
      begin
        if Skipped then
          WriteLn(StdErr, '  = ', Entry^.Id, ' (already installed)')
        else
          WriteLn(StdErr, '  + ', Entry^.Id);
      end
      else
      begin
        WriteLn(StdErr, '  ! ', Entry^.Id, ': ', ErrMsg);
        Inc(DownloadFailures);
      end;
    end;

    Entry := FindArabicEntry('ar.uthmani.min');
    if Entry <> nil then
    begin
      Skipped := False;
      ErrMsg := '';
      if DownloadAndInstallCatalogEntry(Entry, ADataRoot, Skipped, ErrMsg) then
      begin
        if Skipped then
          WriteLn(StdErr, '  = ', Entry^.Id, ' (already installed)')
        else
          WriteLn(StdErr, '  + ', Entry^.Id);
      end
      else
      begin
        WriteLn(StdErr, '  ! ', Entry^.Id, ': ', ErrMsg);
        Inc(DownloadFailures);
      end;
    end;
  end;

  // Summary
  WriteLn(StdErr, '');
  if DownloadFailures > 0 then
  begin
    WriteLn(StdErr, 'Completed with ', DownloadFailures, ' download failure(s).');
    Halt(1);
  end
  else
    WriteLn(StdErr, 'Done.');
end;

// ============================================================================
// CORPUS CLI COMMANDS
// ============================================================================

procedure RunCorpusList(const ADataRoot: String);
var
  CorporaDir: String;
  SR: TSearchRec;
  Manifest: TCorpusManifest;
  ErrMsg, DataFile: String;
  Count: Integer;
begin
  CorporaDir := IncludeTrailingPathDelimiter(ADataRoot) + 'corpora' +
    PathDelim + 'quran';

  if not DirectoryExists(CorporaDir) then
  begin
    WriteLn(StdErr, 'No corpora directory found at: ' + CorporaDir);
    Halt(1);
  end;

  Count := 0;
  if FindFirst(IncludeTrailingPathDelimiter(CorporaDir) + '*',
    faDirectory, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        if (SR.Attr and faDirectory) = 0 then
          Continue;

        if not LoadManifest(
          IncludeTrailingPathDelimiter(CorporaDir) + SR.Name,
          Manifest, ErrMsg) then
        begin
          WriteLn(StdErr, '  ! ', SR.Name, ': ', ErrMsg);
          Continue;
        end;

        Inc(Count);

        // Check for data file
        DataFile := '';
        if FileExists(IncludeTrailingPathDelimiter(Manifest.DirPath) + 'original.tsv') then
          DataFile := 'original.tsv'
        else if FileExists(IncludeTrailingPathDelimiter(Manifest.DirPath) + 'original.jsonl') then
          DataFile := 'original.jsonl';

        WriteLn(Manifest.Id);
        WriteLn('  Title:      ', Manifest.Title);
        if Manifest.Author <> '' then
          WriteLn('  Author:     ', Manifest.Author);
        WriteLn('  Language:   ', Manifest.Language);
        WriteLn('  Kind:       ', KindToStr(Manifest.Kind));
        WriteLn('  Format:     ', FormatToStr(Manifest.Format));
        WriteLn('  Origin:     ', OriginToStr(Manifest.Origin));
        if DataFile <> '' then
          WriteLn('  Data file:  ', DataFile)
        else
          WriteLn('  Data file:  MISSING');
        if Manifest.Checksum <> '' then
          WriteLn('  Checksum:   ', Manifest.Checksum);
        WriteLn('');
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

  WriteLn(StdErr, 'Total: ', Count, ' corpora');
end;

procedure RunCorpusValidate(const ADataRoot, ACorpusId: String);
var
  CorporaDir: String;
  SR: TSearchRec;
  Manifest: TCorpusManifest;
  Store: TVerseStore;
  ErrMsg, DataFile, ActualChecksum: String;
  ValidCount, InvalidCount, TotalCount: Integer;

  procedure ValidateOne(const ADir: String);
  begin
    Inc(TotalCount);
    ErrMsg := '';

    // Step 1: Load manifest
    if not LoadManifest(ADir, Manifest, ErrMsg) then
    begin
      WriteLn('  INVALID  ', ExtractFileName(ExcludeTrailingPathDelimiter(ADir)),
        ': manifest error: ', ErrMsg);
      Inc(InvalidCount);
      Exit;
    end;

    // Step 2: Check required fields
    if (Manifest.Id = '') or (Manifest.Title = '') then
    begin
      WriteLn('  INVALID  ', Manifest.Id, ': missing required fields (id/title)');
      Inc(InvalidCount);
      Exit;
    end;

    // Step 3: Find data file
    if Manifest.Format = cfTsvSurahAyahText then
      DataFile := IncludeTrailingPathDelimiter(ADir) + 'original.tsv'
    else if Manifest.Format = cfJsonlSurahAyahText then
      DataFile := IncludeTrailingPathDelimiter(ADir) + 'original.jsonl'
    else
    begin
      WriteLn('  INVALID  ', Manifest.Id, ': unsupported format: ',
        FormatToStr(Manifest.Format));
      Inc(InvalidCount);
      Exit;
    end;

    if not FileExists(DataFile) then
    begin
      WriteLn('  INVALID  ', Manifest.Id, ': data file not found: ',
        ExtractFileName(DataFile));
      Inc(InvalidCount);
      Exit;
    end;

    // Step 4: Checksum verification
    if Manifest.Checksum <> '' then
    begin
      ActualChecksum := ComputeFileChecksum(DataFile);
      if ActualChecksum <> Manifest.Checksum then
      begin
        WriteLn('  CHECKSUM MISMATCH  ', Manifest.Id);
        WriteLn('    Expected: ', Manifest.Checksum);
        WriteLn('    Actual:   ', ActualChecksum);
        Inc(InvalidCount);
        Exit;
      end;
    end;

    // Step 5: Load and count verses
    if not LoadCorpus(Manifest, Store, ErrMsg) then
    begin
      WriteLn('  INVALID  ', Manifest.Id, ': load error: ', ErrMsg);
      Inc(InvalidCount);
      Exit;
    end;

    if Store.VerseCount = TOTAL_AYAH_COUNT then
      WriteLn('  VALID    ', Manifest.Id, ' (', Store.VerseCount, ' verses)')
    else
      WriteLn('  INCOMPLETE  ', Manifest.Id, ' (', Store.VerseCount,
        '/', TOTAL_AYAH_COUNT, ' verses)');

    Inc(ValidCount);
  end;

begin
  CorporaDir := IncludeTrailingPathDelimiter(ADataRoot) + 'corpora' +
    PathDelim + 'quran';

  if not DirectoryExists(CorporaDir) then
  begin
    WriteLn(StdErr, 'No corpora directory found at: ' + CorporaDir);
    Halt(1);
  end;

  ValidCount := 0;
  InvalidCount := 0;
  TotalCount := 0;

  if ACorpusId <> '' then
  begin
    // Validate a single corpus
    if not DirectoryExists(IncludeTrailingPathDelimiter(CorporaDir) + ACorpusId) then
    begin
      WriteLn(StdErr, 'Corpus not found: ', ACorpusId);
      Halt(1);
    end;
    ValidateOne(IncludeTrailingPathDelimiter(CorporaDir) + ACorpusId);
  end
  else
  begin
    // Validate all corpora
    if FindFirst(IncludeTrailingPathDelimiter(CorporaDir) + '*',
      faDirectory, SR) = 0 then
    begin
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then
            Continue;
          if (SR.Attr and faDirectory) = 0 then
            Continue;
          ValidateOne(IncludeTrailingPathDelimiter(CorporaDir) + SR.Name);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
  end;

  WriteLn('');
  WriteLn('Validated: ', TotalCount, ' corpora (',
    ValidCount, ' valid, ', InvalidCount, ' invalid)');

  if InvalidCount > 0 then
    Halt(1);
end;

procedure RunCorpusAdd(const ADataRoot: String);
var
  Id, FilePath, Format, Title, Author, Kind, Lang, ErrMsg: String;
begin
  Id := GetParam('--id');
  FilePath := GetParam('--file');
  Format := GetParam('--format');
  Title := GetParam('--title');
  Author := GetParam('--translator');
  Kind := GetParam('--kind');
  Lang := GetParam('--lang');

  // Validate required params
  if Id = '' then
  begin
    WriteLn(StdErr, 'Error: --id is required');
    WriteLn(StdErr, 'Usage: quran-tafseer-mcp corpus add --data <path> --id <id> --file <path> --format <fmt> --title "..." [--translator "..."] [--kind translation] [--lang en]');
    Halt(1);
  end;
  if FilePath = '' then
  begin
    WriteLn(StdErr, 'Error: --file is required');
    Halt(1);
  end;
  if Format = '' then
  begin
    WriteLn(StdErr, 'Error: --format is required (tsv_surah_ayah_text or jsonl_surah_ayah_text)');
    Halt(1);
  end;
  if Title = '' then
  begin
    WriteLn(StdErr, 'Error: --title is required');
    Halt(1);
  end;

  // Defaults
  if Kind = '' then
    Kind := 'translation';
  if Lang = '' then
    Lang := 'en';

  WriteLn(StdErr, 'Adding corpus: ', Id);
  WriteLn(StdErr, '  File:   ', FilePath);
  WriteLn(StdErr, '  Format: ', Format);

  ErrMsg := '';
  if not InstallLocalCorpus(FilePath, Id, Kind, Lang, Format, Title,
    Author, ADataRoot, ErrMsg) then
  begin
    WriteLn(StdErr, 'Error: ', ErrMsg);
    Halt(1);
  end;

  WriteLn(StdErr, 'Corpus installed successfully.');

  // Build FTS5 index
  WriteLn(StdErr, 'Building search index...');
  // Need to init corpus store first so BuildIndex can find the corpus
  InitCorpusStore(ADataRoot);
  if BuildIndex(Id, ADataRoot) then
    WriteLn(StdErr, 'Index built.')
  else
    WriteLn(StdErr, 'Warning: Failed to build search index.');

  WriteLn(StdErr, 'Done.');
end;

var
  Cmd, DataRoot, LogLevelStr, BundledDir, CatalogPath, CatErr: String;
  CorpusCount, I, J: Integer;
  ExePath, CorpusIdArg: String;
  Report: TInstallReport;
  Store: PVerseStore;
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
      DataRoot := GetDefaultDataRoot;

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

    // Resolve bundled path
    BundledDir := GetParam('--bundled-path');
    if BundledDir = '' then
    begin
      ExePath := ExtractFilePath(ParamStr(0));
      BundledDir := ExePath + 'bundled' + PathDelim + 'quran';
    end;
    SetBundledPath(BundledDir);
    LogDebug('Bundled path: ' + BundledDir);

    // Load catalog (always relative to the executable)
    CatalogPath := ExtractFilePath(ParamStr(0)) + 'catalog' +
      PathDelim + 'translations.json';
    CatErr := '';
    if FileExists(CatalogPath) then
    begin
      if LoadCatalog(CatalogPath, CatErr) then
        LogInfo('Catalog loaded from: ' + CatalogPath)
      else
        LogWarn('Failed to load catalog: ' + CatErr);
    end
    else
      LogDebug('Catalog not found at: ' + CatalogPath);

    // Initialize corpus store
    CorpusCount := InitCorpusStore(DataRoot);
    LogInfo('Corpora loaded: ' + IntToStr(CorpusCount));

    // Auto-trigger: if no corpora loaded, install bundled
    if (CorpusCount = 0) and DirectoryExists(BundledDir) then
    begin
      LogInfo('No corpora found — auto-installing bundled corpora');
      Report := InstallBundledCorpora(BundledDir, DataRoot);
      if Length(Report.Installed) > 0 then
      begin
        LogInfo('Auto-installed ' + IntToStr(Length(Report.Installed)) +
          ' bundled corpora');
        // Re-scan
        CorpusCount := InitCorpusStore(DataRoot);
        LogInfo('Corpora after auto-install: ' + IntToStr(CorpusCount));
      end;
    end;

    // Auto-build missing indexes
    if CorpusCount > 0 then
    begin
      I := 0;
      for J := 0 to GetCorpusCount - 1 do
      begin
        Store := GetCorpusByIndex(J);
        if (Store <> nil) and (not IndexExists(Store^.Manifest.Id, DataRoot)) then
          Inc(I);
      end;
      if I > 0 then
      begin
        LogInfo('Building search indexes for ' + IntToStr(I) + ' corpora...');
        J := BuildAllIndexes(DataRoot);
        LogInfo('Built ' + IntToStr(J) + ' search indexes');
      end;
    end;

    InitJsonRpcTransport;
    RunMcpLoop;
  end
  else if Cmd = 'init' then
  begin
    DataRoot := GetParam('--data');
    if DataRoot = '' then
      DataRoot := GetDefaultDataRoot;

    WriteLn(StdErr, 'Data root: ' + DataRoot);

    // Create data root if needed
    if not DirectoryExists(DataRoot) then
    begin
      if not ForceDirectories(DataRoot) then
      begin
        WriteLn(StdErr, 'Error: Cannot create data root: ' + DataRoot);
        Halt(1);
      end;
    end;

    // Resolve bundled path
    BundledDir := GetParam('--bundled-path');
    if BundledDir = '' then
      BundledDir := ExtractFilePath(ParamStr(0)) + 'bundled' + PathDelim + 'quran';

    if HasParam('--bundled-only') then
      RunInitBundledOnly(DataRoot, BundledDir)
    else
      RunInitFull(DataRoot, BundledDir, HasParam('--all'));
  end
  else if Cmd = 'index' then
  begin
    // quran-tafseer-mcp index build --data <path> [--id <corpus-id> | --all]
    DataRoot := GetParam('--data');
    if DataRoot = '' then
      DataRoot := GetDefaultDataRoot;

    WriteLn(StdErr, 'Data root: ' + DataRoot);

    if not DirectoryExists(DataRoot) then
    begin
      WriteLn(StdErr, 'Error: Data root does not exist: ' + DataRoot);
      Halt(1);
    end;

    // Check for 'build' subcommand
    if (ParamCount < 2) or (ParamStr(2) <> 'build') then
    begin
      WriteLn(StdErr, 'Usage: quran-tafseer-mcp index build --data <path> [--id <corpus-id> | --all]');
      Halt(1);
    end;

    // Load corpora
    CorpusCount := InitCorpusStore(DataRoot);
    if CorpusCount = 0 then
    begin
      WriteLn(StdErr, 'No corpora found in: ' + DataRoot);
      Halt(1);
    end;
    WriteLn(StdErr, 'Loaded ', CorpusCount, ' corpora.');

    CorpusIdArg := GetParam('--id');
    if CorpusIdArg <> '' then
    begin
      // Build index for a single corpus
      Store := FindCorpus(CorpusIdArg);
      if Store = nil then
      begin
        WriteLn(StdErr, 'Corpus not found: ' + CorpusIdArg);
        Halt(1);
      end;
      WriteLn(StdErr, 'Building index for: ' + CorpusIdArg);
      if BuildIndex(CorpusIdArg, DataRoot) then
        WriteLn(StdErr, 'Done.')
      else
      begin
        WriteLn(StdErr, 'Failed to build index.');
        Halt(1);
      end;
    end
    else
    begin
      // Build all indexes
      WriteLn(StdErr, 'Building indexes for all corpora...');
      J := BuildAllIndexes(DataRoot);
      WriteLn(StdErr, 'Built ', J, ' indexes.');
    end;
  end
  else if Cmd = 'corpus' then
  begin
    DataRoot := GetParam('--data');
    if DataRoot = '' then
      DataRoot := GetDefaultDataRoot;

    WriteLn(StdErr, 'Data root: ' + DataRoot);

    if ParamCount < 2 then
    begin
      WriteLn(StdErr, 'Usage: quran-tafseer-mcp corpus <list|validate|add> --data <path>');
      Halt(1);
    end;

    // ======================================================================
    // corpus list
    // ======================================================================
    if ParamStr(2) = 'list' then
    begin
      RunCorpusList(DataRoot);
    end
    // ======================================================================
    // corpus validate
    // ======================================================================
    else if ParamStr(2) = 'validate' then
    begin
      CorpusIdArg := GetParam('--id');
      RunCorpusValidate(DataRoot, CorpusIdArg);
    end
    // ======================================================================
    // corpus add
    // ======================================================================
    else if ParamStr(2) = 'add' then
    begin
      RunCorpusAdd(DataRoot);
    end
    else
    begin
      WriteLn(StdErr, 'Unknown corpus subcommand: ', ParamStr(2));
      WriteLn(StdErr, 'Usage: quran-tafseer-mcp corpus <list|validate|add> --data <path>');
      Halt(1);
    end;
  end
  else if (Cmd = 'setup') or (Cmd = 'catalog') then
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
