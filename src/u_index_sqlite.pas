unit u_index_sqlite;

{$mode objfpc}{$H+}

interface

type
  TSearchHit = record
    Surah: Integer;
    Ayah: Integer;
    Snippet: String;
    Score: Double;
  end;
  TSearchResults = array of TSearchHit;

/// Build a SQLite FTS5 index for a single corpus.
/// Reads all verses from the in-memory corpus store and inserts them into
/// a SQLite database at <DataRoot>/indexes/quran/<CorpusId>.sqlite.
/// Returns True on success.
function BuildIndex(const ACorpusId, ADataRoot: String): Boolean;

/// Build indexes for all loaded corpora. Returns count built.
function BuildAllIndexes(const ADataRoot: String): Integer;

/// Search a corpus index using FTS5. Returns True on success.
/// Results are ranked by FTS5 relevance score.
function SearchIndex(const ACorpusId, ADataRoot, AQuery: String;
  ALimit: Integer; out AResults: TSearchResults): Boolean;

/// Check if an index file exists for a corpus.
function IndexExists(const ACorpusId, ADataRoot: String): Boolean;

/// Get the file path for a corpus index.
function GetIndexPath(const ACorpusId, ADataRoot: String): String;

implementation

uses
  SysUtils, sqlite3, u_log, u_corpus_store, u_corpus_reader,
  u_quran_metadata;

// ============================================================================
// SQLite helpers
// ============================================================================

function SqliteExec(ADb: Pointer; const ASql: String;
  out AErrMsg: String): Boolean;
var
  ErrPtr: PAnsiChar;
  RC: Integer;
begin
  ErrPtr := nil;
  RC := sqlite3_exec(ADb, PAnsiChar(AnsiString(ASql)), nil, nil, @ErrPtr);
  if RC <> SQLITE_OK then
  begin
    if ErrPtr <> nil then
    begin
      AErrMsg := String(AnsiString(ErrPtr));
      sqlite3_free(ErrPtr);
    end
    else
      AErrMsg := 'SQLite error code: ' + IntToStr(RC);
    Result := False;
  end
  else
  begin
    AErrMsg := '';
    Result := True;
  end;
end;

function GetIndexPath(const ACorpusId, ADataRoot: String): String;
begin
  Result := IncludeTrailingPathDelimiter(ADataRoot) + 'indexes' +
    PathDelim + 'quran' + PathDelim + ACorpusId + '.sqlite';
end;

function IndexExists(const ACorpusId, ADataRoot: String): Boolean;
begin
  Result := FileExists(GetIndexPath(ACorpusId, ADataRoot));
end;

// ============================================================================
// Index building
// ============================================================================

function BuildIndex(const ACorpusId, ADataRoot: String): Boolean;
var
  Store: PVerseStore;
  IndexPath, IndexDir, ErrMsg, Text: String;
  Db: Pointer;
  Stmt: Pointer;
  RC, Surah, Ayah, MaxAyah, RowId: Integer;
begin
  Result := False;
  Db := nil;
  Stmt := nil;

  Store := FindCorpus(ACorpusId);
  if Store = nil then
  begin
    LogWarn('BuildIndex: corpus not found: ' + ACorpusId);
    Exit;
  end;

  IndexPath := GetIndexPath(ACorpusId, ADataRoot);
  IndexDir := ExtractFilePath(IndexPath);

  // Create indexes directory if needed
  if not DirectoryExists(IndexDir) then
  begin
    if not ForceDirectories(IndexDir) then
    begin
      LogError('BuildIndex: cannot create directory: ' + IndexDir);
      Exit;
    end;
  end;

  // Delete existing index if present
  if FileExists(IndexPath) then
    DeleteFile(IndexPath);

  // Open database
  RC := sqlite3_open(PAnsiChar(AnsiString(IndexPath)), @Db);
  if RC <> SQLITE_OK then
  begin
    LogError('BuildIndex: cannot open database: ' + IndexPath);
    if Db <> nil then
      sqlite3_close(Db);
    Exit;
  end;

  try
    // Create schema
    if not SqliteExec(Db,
      'CREATE TABLE verses (rowid INTEGER PRIMARY KEY, surah INT, ayah INT, text TEXT)',
      ErrMsg) then
    begin
      LogError('BuildIndex: create table failed: ' + ErrMsg);
      Exit;
    end;

    if not SqliteExec(Db,
      'CREATE VIRTUAL TABLE verses_fts USING fts5(text, content=''verses'', content_rowid=''rowid'', tokenize=''unicode61'')',
      ErrMsg) then
    begin
      LogError('BuildIndex: create FTS table failed: ' + ErrMsg);
      Exit;
    end;

    // Begin transaction for bulk insert
    if not SqliteExec(Db, 'BEGIN TRANSACTION', ErrMsg) then
    begin
      LogError('BuildIndex: begin transaction failed: ' + ErrMsg);
      Exit;
    end;

    // Prepare insert statement
    RC := sqlite3_prepare_v2(Db,
      PAnsiChar('INSERT INTO verses (rowid, surah, ayah, text) VALUES (?, ?, ?, ?)'),
      -1, @Stmt, nil);
    if RC <> SQLITE_OK then
    begin
      LogError('BuildIndex: prepare insert failed');
      SqliteExec(Db, 'ROLLBACK', ErrMsg);
      Exit;
    end;

    // Insert all verses
    RowId := 0;
    for Surah := 1 to SURAH_COUNT do
    begin
      MaxAyah := GetAyahCount(Surah);
      for Ayah := 1 to MaxAyah do
      begin
        Text := GetVerse(Store^, Surah, Ayah);
        if Text = '' then
          Continue;

        Inc(RowId);
        sqlite3_reset(Stmt);
        sqlite3_bind_int(Stmt, 1, RowId);
        sqlite3_bind_int(Stmt, 2, Surah);
        sqlite3_bind_int(Stmt, 3, Ayah);
        sqlite3_bind_text(Stmt, 4, PAnsiChar(AnsiString(Text)), -1, sqlite3_destructor_type(Pointer(-1)));

        RC := sqlite3_step(Stmt);
        if RC <> SQLITE_DONE then
        begin
          LogWarn('BuildIndex: insert failed for ' + IntToStr(Surah) + ':' +
            IntToStr(Ayah));
        end;
      end;
    end;

    sqlite3_finalize(Stmt);
    Stmt := nil;

    // Populate FTS index from content table
    if not SqliteExec(Db,
      'INSERT INTO verses_fts(verses_fts) VALUES (''rebuild'')',
      ErrMsg) then
    begin
      LogError('BuildIndex: FTS rebuild failed: ' + ErrMsg);
      SqliteExec(Db, 'ROLLBACK', ErrMsg);
      Exit;
    end;

    // Commit
    if not SqliteExec(Db, 'COMMIT', ErrMsg) then
    begin
      LogError('BuildIndex: commit failed: ' + ErrMsg);
      Exit;
    end;

    LogInfo('BuildIndex: indexed ' + IntToStr(RowId) + ' verses for ' + ACorpusId);
    Result := True;
  finally
    if Stmt <> nil then
      sqlite3_finalize(Stmt);
    if Db <> nil then
      sqlite3_close(Db);
  end;
end;

function BuildAllIndexes(const ADataRoot: String): Integer;
var
  I: Integer;
  Store: PVerseStore;
begin
  Result := 0;
  for I := 0 to GetCorpusCount - 1 do
  begin
    Store := GetCorpusByIndex(I);
    if Store = nil then
      Continue;
    if BuildIndex(Store^.Manifest.Id, ADataRoot) then
      Inc(Result);
  end;
end;

// ============================================================================
// Search
// ============================================================================

function SearchIndex(const ACorpusId, ADataRoot, AQuery: String;
  ALimit: Integer; out AResults: TSearchResults): Boolean;
var
  IndexPath, Sql: String;
  Db: Pointer;
  Stmt: Pointer;
  RC, Count: Integer;
  SnippetPtr: PAnsiChar;
begin
  Result := False;
  SetLength(AResults, 0);
  Db := nil;
  Stmt := nil;

  IndexPath := GetIndexPath(ACorpusId, ADataRoot);
  if not FileExists(IndexPath) then
  begin
    LogWarn('SearchIndex: index not found: ' + IndexPath);
    Exit;
  end;

  // Open read-only
  RC := sqlite3_open_v2(PAnsiChar(AnsiString(IndexPath)), @Db,
    SQLITE_OPEN_READONLY, nil);
  if RC <> SQLITE_OK then
  begin
    LogError('SearchIndex: cannot open index: ' + IndexPath);
    if Db <> nil then
      sqlite3_close(Db);
    Exit;
  end;

  try
    // Query: join FTS with content table to get surah, ayah, snippet, score
    Sql := 'SELECT v.surah, v.ayah, ' +
           'snippet(verses_fts, 0, ''<b>'', ''</b>'', ''...'', 40), ' +
           'rank ' +
           'FROM verses_fts ' +
           'JOIN verses v ON v.rowid = verses_fts.rowid ' +
           'WHERE verses_fts MATCH ? ' +
           'ORDER BY rank ' +
           'LIMIT ?';

    RC := sqlite3_prepare_v2(Db, PAnsiChar(AnsiString(Sql)), -1, @Stmt, nil);
    if RC <> SQLITE_OK then
    begin
      LogError('SearchIndex: prepare query failed for ' + ACorpusId +
        ': ' + String(AnsiString(sqlite3_errmsg(Db))));
      Exit;
    end;

    sqlite3_bind_text(Stmt, 1, PAnsiChar(AnsiString(AQuery)), -1, sqlite3_destructor_type(Pointer(-1)));
    sqlite3_bind_int(Stmt, 2, ALimit);

    Count := 0;
    SetLength(AResults, ALimit);

    while sqlite3_step(Stmt) = SQLITE_ROW do
    begin
      if Count >= ALimit then
        Break;

      AResults[Count].Surah := sqlite3_column_int(Stmt, 0);
      AResults[Count].Ayah := sqlite3_column_int(Stmt, 1);

      SnippetPtr := sqlite3_column_text(Stmt, 2);
      if SnippetPtr <> nil then
        AResults[Count].Snippet := String(AnsiString(SnippetPtr))
      else
        AResults[Count].Snippet := '';

      // FTS5 rank is negative (more negative = better match)
      // Convert to positive score for external use
      AResults[Count].Score := -sqlite3_column_double(Stmt, 3);

      Inc(Count);
    end;

    SetLength(AResults, Count);
    Result := True;

    LogDebug('SearchIndex: ' + IntToStr(Count) + ' hits for "' + AQuery +
      '" in ' + ACorpusId);
  finally
    if Stmt <> nil then
      sqlite3_finalize(Stmt);
    if Db <> nil then
      sqlite3_close(Db);
  end;
end;

end.
