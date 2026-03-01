unit u_corpus_store;

{$mode objfpc}{$H+}

interface

uses
  u_corpus_manifest, u_corpus_reader;

/// Initialize the corpus store by scanning the data root for corpora.
/// Scans <DataRoot>/corpora/quran/ for subdirectories with manifest.json.
/// Returns the number of corpora loaded.
function InitCorpusStore(const ADataRoot: String): Integer;

/// Get the number of loaded corpora.
function GetCorpusCount: Integer;

/// Get a corpus store by index (0-based).
function GetCorpusByIndex(AIndex: Integer): PVerseStore;

/// Find a corpus store by its manifest ID. Returns nil if not found.
function FindCorpus(const AId: String): PVerseStore;

/// Get verse text from a specific corpus. Returns empty string if not found.
function LookupVerse(const ACorpusId: String; ASurah, AAyah: Integer): String;

/// Get the current data root path.
function GetDataRoot: String;

/// Set the bundled corpora path (where bundled/ lives).
procedure SetBundledPath(const APath: String);

/// Get the bundled corpora path.
function GetBundledPath: String;

implementation

uses
  SysUtils, u_log;

var
  Corpora: array of TVerseStore;
  CorporaCount: Integer = 0;
  DataRoot: String = '';
  BundledPath: String = '';

function InitCorpusStore(const ADataRoot: String): Integer;
var
  CorporaDir: String;
  SR: TSearchRec;
  Manifest: TCorpusManifest;
  Store: TVerseStore;
  ErrMsg: String;
begin
  Result := 0;
  DataRoot := ADataRoot;
  CorporaCount := 0;
  SetLength(Corpora, 0);

  CorporaDir := IncludeTrailingPathDelimiter(ADataRoot) + 'corpora' +
    PathDelim + 'quran';

  if not DirectoryExists(CorporaDir) then
  begin
    LogInfo('Corpora directory does not exist: ' + CorporaDir);
    Exit;
  end;

  LogInfo('Scanning corpora in: ' + CorporaDir);

  if FindFirst(IncludeTrailingPathDelimiter(CorporaDir) + '*',
    faDirectory, SR) = 0 then
  begin
    try
      repeat
        // Skip . and ..
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        // Only directories
        if (SR.Attr and faDirectory) = 0 then
          Continue;

        // Try to load manifest
        if not LoadManifest(
          IncludeTrailingPathDelimiter(CorporaDir) + SR.Name,
          Manifest, ErrMsg) then
        begin
          LogWarn('Skipping ' + SR.Name + ': ' + ErrMsg);
          Continue;
        end;

        // Load corpus data
        if not LoadCorpus(Manifest, Store, ErrMsg) then
        begin
          LogWarn('Failed to load corpus ' + Manifest.Id + ': ' + ErrMsg);
          Continue;
        end;

        // Add to array
        Inc(CorporaCount);
        SetLength(Corpora, CorporaCount);
        Corpora[CorporaCount - 1] := Store;

        LogInfo('Loaded corpus: ' + Manifest.Id +
          ' (' + IntToStr(Store.VerseCount) + ' verses)');
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

  LogInfo('Total corpora loaded: ' + IntToStr(CorporaCount));
  Result := CorporaCount;
end;

function GetCorpusCount: Integer;
begin
  Result := CorporaCount;
end;

function GetCorpusByIndex(AIndex: Integer): PVerseStore;
begin
  if (AIndex >= 0) and (AIndex < CorporaCount) then
    Result := @Corpora[AIndex]
  else
    Result := nil;
end;

function FindCorpus(const AId: String): PVerseStore;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to CorporaCount - 1 do
  begin
    if Corpora[I].Manifest.Id = AId then
    begin
      Result := @Corpora[I];
      Exit;
    end;
  end;
end;

function LookupVerse(const ACorpusId: String; ASurah, AAyah: Integer): String;
var
  Store: PVerseStore;
begin
  Result := '';
  Store := FindCorpus(ACorpusId);
  if Store <> nil then
    Result := GetVerse(Store^, ASurah, AAyah);
end;

function GetDataRoot: String;
begin
  Result := DataRoot;
end;

procedure SetBundledPath(const APath: String);
begin
  BundledPath := APath;
end;

function GetBundledPath: String;
begin
  Result := BundledPath;
end;

end.
