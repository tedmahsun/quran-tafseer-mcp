unit u_corpus_reader;

{$mode objfpc}{$H+}

interface

uses
  u_corpus_manifest;

type
  /// In-memory verse store for a single corpus.
  /// Verses are stored in a flat array indexed by (surah * 1000 + ayah).
  /// Max index: 114 * 1000 + 286 = 114286.
  TVerseStore = record
    Manifest: TCorpusManifest;
    Verses: array of String;  // indexed by surah*1000+ayah
    Loaded: Boolean;
    VerseCount: Integer;      // number of verses actually loaded
  end;
  PVerseStore = ^TVerseStore;

const
  VERSE_ARRAY_SIZE = 115000;  // > 114*1000+286

/// Load verses from a corpus directory into a TVerseStore.
/// Returns True on success.
function LoadCorpus(const AManifest: TCorpusManifest;
  out AStore: TVerseStore; out AError: String): Boolean;

/// Get verse text from a loaded store. Returns empty string if not found.
function GetVerse(const AStore: TVerseStore; ASurah, AAyah: Integer): String;

/// Check if a verse exists in the store.
function HasVerse(const AStore: TVerseStore; ASurah, AAyah: Integer): Boolean;

/// Load verses from a TSV file into a pre-allocated verse store.
/// AStore.Verses must already be SetLength'd to VERSE_ARRAY_SIZE.
function LoadTsvFile(const AFilePath: String; var AStore: TVerseStore;
  out AError: String): Boolean;

/// Load verses from a JSONL file into a pre-allocated verse store.
/// AStore.Verses must already be SetLength'd to VERSE_ARRAY_SIZE.
function LoadJsonlFile(const AFilePath: String; var AStore: TVerseStore;
  out AError: String): Boolean;

implementation

uses
  SysUtils, Classes, fpjson, jsonparser, u_log;

function VerseIndex(ASurah, AAyah: Integer): Integer; inline;
begin
  Result := ASurah * 1000 + AAyah;
end;

function LoadTsvFile(const AFilePath: String; var AStore: TVerseStore;
  out AError: String): Boolean;
var
  F: TextFile;
  Line, SurahStr, AyahStr, Text: String;
  Surah, Ayah, Idx, Tab1, Tab2, LineNum, I: Integer;
begin
  Result := False;
  AStore.VerseCount := 0;

  AssignFile(F, AFilePath);
  {$I-}
  Reset(F);
  {$I+}
  if IOResult <> 0 then
  begin
    AError := 'Cannot open file: ' + AFilePath;
    Exit;
  end;

  LineNum := 0;
  try
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      Inc(LineNum);

      // Skip empty lines
      if Length(Line) = 0 then
        Continue;

      // Skip comment lines
      if Line[1] = '#' then
        Continue;

      // Parse: surah<TAB>ayah<TAB>text
      Tab1 := Pos(#9, Line);
      if Tab1 = 0 then
      begin
        LogWarn('Line ' + IntToStr(LineNum) + ': no tab delimiter, skipping');
        Continue;
      end;

      SurahStr := Copy(Line, 1, Tab1 - 1);
      Tab2 := 0;
      // Find second tab after first
      for I := Tab1 + 1 to Length(Line) do
      begin
        if Line[I] = #9 then
        begin
          Tab2 := I;
          Break;
        end;
      end;

      if Tab2 = 0 then
      begin
        LogWarn('Line ' + IntToStr(LineNum) + ': missing second tab, skipping');
        Continue;
      end;

      AyahStr := Copy(Line, Tab1 + 1, Tab2 - Tab1 - 1);
      Text := Copy(Line, Tab2 + 1, Length(Line) - Tab2);

      Surah := StrToIntDef(SurahStr, 0);
      Ayah := StrToIntDef(AyahStr, 0);

      if (Surah < 1) or (Surah > 114) or (Ayah < 1) or (Ayah > 999) then
      begin
        LogWarn('Line ' + IntToStr(LineNum) + ': invalid surah/ayah (' +
          SurahStr + '/' + AyahStr + '), skipping');
        Continue;
      end;

      Idx := VerseIndex(Surah, Ayah);
      if Idx < VERSE_ARRAY_SIZE then
      begin
        if AStore.Verses[Idx] = '' then
          Inc(AStore.VerseCount);
        AStore.Verses[Idx] := Text;
      end;
    end;
  finally
    CloseFile(F);
  end;

  LogInfo('Loaded ' + IntToStr(AStore.VerseCount) + ' verses from ' + AFilePath);
  Result := True;
end;

function LoadJsonlFile(const AFilePath: String; var AStore: TVerseStore;
  out AError: String): Boolean;
var
  F: TextFile;
  Line: String;
  LineNum, Surah, Ayah, Idx: Integer;
  Data: TJSONData;
  Obj: TJSONObject;
begin
  Result := False;
  AStore.VerseCount := 0;

  AssignFile(F, AFilePath);
  {$I-}
  Reset(F);
  {$I+}
  if IOResult <> 0 then
  begin
    AError := 'Cannot open file: ' + AFilePath;
    Exit;
  end;

  LineNum := 0;
  try
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      Inc(LineNum);

      // Skip empty lines
      if Length(Line) = 0 then
        Continue;

      // Skip comment lines
      if Line[1] = '#' then
        Continue;

      // Parse JSON object
      Data := nil;
      try
        Data := GetJSON(Line);
      except
        on E: Exception do
        begin
          LogWarn('Line ' + IntToStr(LineNum) + ': JSON parse error: ' +
            E.Message + ', skipping');
          Continue;
        end;
      end;

      if not (Data is TJSONObject) then
      begin
        LogWarn('Line ' + IntToStr(LineNum) + ': not a JSON object, skipping');
        Data.Free;
        Continue;
      end;

      Obj := TJSONObject(Data);
      try
        Surah := Obj.Get('surah', 0);
        Ayah := Obj.Get('ayah', 0);

        if (Surah < 1) or (Surah > 114) or (Ayah < 1) or (Ayah > 999) then
        begin
          LogWarn('Line ' + IntToStr(LineNum) + ': invalid surah/ayah (' +
            IntToStr(Surah) + '/' + IntToStr(Ayah) + '), skipping');
          Continue;
        end;

        Idx := VerseIndex(Surah, Ayah);
        if Idx < VERSE_ARRAY_SIZE then
        begin
          if AStore.Verses[Idx] = '' then
            Inc(AStore.VerseCount);
          AStore.Verses[Idx] := Obj.Get('text', '');
        end;
      finally
        Obj.Free;
      end;
    end;
  finally
    CloseFile(F);
  end;

  LogInfo('Loaded ' + IntToStr(AStore.VerseCount) + ' verses from ' + AFilePath);
  Result := True;
end;

function LoadCorpus(const AManifest: TCorpusManifest;
  out AStore: TVerseStore; out AError: String): Boolean;
var
  FilePath: String;
begin
  Result := False;
  AError := '';

  AStore.Manifest := AManifest;
  AStore.Loaded := False;
  AStore.VerseCount := 0;
  SetLength(AStore.Verses, VERSE_ARRAY_SIZE);

  case AManifest.Format of
    cfTsvSurahAyahText:
    begin
      FilePath := IncludeTrailingPathDelimiter(AManifest.DirPath) + 'original.tsv';
      if not FileExists(FilePath) then
      begin
        AError := 'Corpus file not found: ' + FilePath;
        Exit;
      end;
      Result := LoadTsvFile(FilePath, AStore, AError);
    end;
    cfJsonlSurahAyahText:
    begin
      FilePath := IncludeTrailingPathDelimiter(AManifest.DirPath) + 'original.jsonl';
      if not FileExists(FilePath) then
      begin
        AError := 'Corpus file not found: ' + FilePath;
        Exit;
      end;
      Result := LoadJsonlFile(FilePath, AStore, AError);
    end;
    else
    begin
      AError := 'Unsupported format for corpus ' + AManifest.Id;
      Exit;
    end;
  end;

  if Result then
    AStore.Loaded := True;
end;

function GetVerse(const AStore: TVerseStore; ASurah, AAyah: Integer): String;
var
  Idx: Integer;
begin
  Result := '';
  if not AStore.Loaded then
    Exit;
  Idx := VerseIndex(ASurah, AAyah);
  if (Idx >= 0) and (Idx < VERSE_ARRAY_SIZE) then
    Result := AStore.Verses[Idx];
end;

function HasVerse(const AStore: TVerseStore; ASurah, AAyah: Integer): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  if not AStore.Loaded then
    Exit;
  Idx := VerseIndex(ASurah, AAyah);
  if (Idx >= 0) and (Idx < VERSE_ARRAY_SIZE) then
    Result := AStore.Verses[Idx] <> '';
end;

end.
