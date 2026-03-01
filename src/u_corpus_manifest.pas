unit u_corpus_manifest;

{$mode objfpc}{$H+}

interface

type
  TCorpusKind = (ckArabic, ckTranslation);
  TCorpusFormat = (cfTsvSurahAyahText, cfJsonlSurahAyahText, cfSqlite);
  TCorpusOrigin = (coBundle, coDownloaded, coManualImport, coTestFixture);

  TCorpusManifest = record
    Id: String;
    Kind: TCorpusKind;
    Language: String;
    Title: String;
    Author: String;        // author or translator
    Source: String;
    LicenseNote: String;
    Format: TCorpusFormat;
    Checksum: String;
    Origin: TCorpusOrigin;
    CreatedAt: String;
    DirPath: String;       // directory containing this manifest (set at load time)
  end;
  PCorpusManifest = ^TCorpusManifest;

/// Load a corpus manifest from a directory containing manifest.json.
/// Returns True on success, False on error (with AError message).
function LoadManifest(const ADirPath: String; out AManifest: TCorpusManifest;
  out AError: String): Boolean;

/// Parse a corpus format string into the enum value.
function ParseFormat(const AStr: String): TCorpusFormat;

/// Return a human-readable string for a format enum.
function FormatToStr(AFormat: TCorpusFormat): String;

/// Return a human-readable string for a kind enum.
function KindToStr(AKind: TCorpusKind): String;

/// Return a human-readable string for an origin enum.
function OriginToStr(AOrigin: TCorpusOrigin): String;

implementation

uses
  SysUtils, fpjson, jsonparser, u_log;

function ParseKind(const AStr: String): TCorpusKind;
begin
  if AStr = 'quran_arabic' then
    Result := ckArabic
  else
    Result := ckTranslation;
end;

function ParseFormat(const AStr: String): TCorpusFormat;
begin
  if AStr = 'jsonl_surah_ayah_text' then
    Result := cfJsonlSurahAyahText
  else if AStr = 'sqlite' then
    Result := cfSqlite
  else
    Result := cfTsvSurahAyahText;
end;

function ParseOrigin(const AStr: String): TCorpusOrigin;
begin
  if AStr = 'bundled' then
    Result := coBundle
  else if AStr = 'downloaded' then
    Result := coDownloaded
  else if AStr = 'manual_import' then
    Result := coManualImport
  else if AStr = 'test_fixture' then
    Result := coTestFixture
  else
    Result := coManualImport;
end;

function FormatToStr(AFormat: TCorpusFormat): String;
begin
  case AFormat of
    cfTsvSurahAyahText: Result := 'tsv_surah_ayah_text';
    cfJsonlSurahAyahText: Result := 'jsonl_surah_ayah_text';
    cfSqlite: Result := 'sqlite';
    else Result := 'unknown';
  end;
end;

function KindToStr(AKind: TCorpusKind): String;
begin
  case AKind of
    ckArabic: Result := 'quran_arabic';
    ckTranslation: Result := 'translation';
    else Result := 'unknown';
  end;
end;

function OriginToStr(AOrigin: TCorpusOrigin): String;
begin
  case AOrigin of
    coBundle: Result := 'bundled';
    coDownloaded: Result := 'downloaded';
    coManualImport: Result := 'manual_import';
    coTestFixture: Result := 'test_fixture';
    else Result := 'unknown';
  end;
end;

function LoadManifest(const ADirPath: String; out AManifest: TCorpusManifest;
  out AError: String): Boolean;
var
  ManifestPath, JsonStr: String;
  F: TextFile;
  Data: TJSONData;
  Obj: TJSONObject;
  Line: String;
begin
  Result := False;
  AError := '';

  // Initialize record
  AManifest.Id := '';
  AManifest.Kind := ckTranslation;
  AManifest.Language := '';
  AManifest.Title := '';
  AManifest.Author := '';
  AManifest.Source := '';
  AManifest.LicenseNote := '';
  AManifest.Format := cfTsvSurahAyahText;
  AManifest.Checksum := '';
  AManifest.Origin := coManualImport;
  AManifest.CreatedAt := '';
  AManifest.DirPath := ADirPath;

  ManifestPath := IncludeTrailingPathDelimiter(ADirPath) + 'manifest.json';

  if not FileExists(ManifestPath) then
  begin
    AError := 'manifest.json not found in ' + ADirPath;
    Exit;
  end;

  // Read file contents
  JsonStr := '';
  AssignFile(F, ManifestPath);
  {$I-}
  Reset(F);
  {$I+}
  if IOResult <> 0 then
  begin
    AError := 'Cannot open ' + ManifestPath;
    Exit;
  end;
  try
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      JsonStr := JsonStr + Line;
    end;
  finally
    CloseFile(F);
  end;

  // Parse JSON
  Data := nil;
  try
    Data := GetJSON(JsonStr);
  except
    on E: Exception do
    begin
      AError := 'JSON parse error in ' + ManifestPath + ': ' + E.Message;
      Exit;
    end;
  end;

  if not (Data is TJSONObject) then
  begin
    AError := 'manifest.json root is not a JSON object';
    Data.Free;
    Exit;
  end;

  Obj := TJSONObject(Data);
  try
    // Required fields
    AManifest.Id := Obj.Get('id', '');
    if AManifest.Id = '' then
    begin
      AError := 'Missing required field: id';
      Exit;
    end;

    AManifest.Kind := ParseKind(Obj.Get('kind', ''));
    AManifest.Language := Obj.Get('language', '');
    AManifest.Title := Obj.Get('title', '');
    AManifest.Format := ParseFormat(Obj.Get('format', ''));

    // Optional fields
    if Obj.IndexOfName('author') >= 0 then
      AManifest.Author := Obj.Get('author', '')
    else if Obj.IndexOfName('translator') >= 0 then
      AManifest.Author := Obj.Get('translator', '');

    AManifest.Source := Obj.Get('source', '');
    AManifest.LicenseNote := Obj.Get('license_note', '');
    AManifest.Checksum := Obj.Get('checksum', '');
    AManifest.Origin := ParseOrigin(Obj.Get('origin', ''));
    AManifest.CreatedAt := Obj.Get('created_at', '');

    LogDebug('Loaded manifest: ' + AManifest.Id + ' (' + AManifest.Title + ')');
    Result := True;
  finally
    Obj.Free;
  end;
end;

end.
