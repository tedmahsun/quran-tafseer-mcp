unit u_tools_setup;

{$mode objfpc}{$H+}

interface

uses
  fpjson, u_jsonrpc;

/// Build the tool schema for quran.setup (for tools/list registration).
function BuildToolSchema_Setup: TJSONObject;

/// Handle quran.setup tool call with action-based dispatch.
function HandleSetup(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;

implementation

uses
  SysUtils, u_log, u_mcp, u_tools_quran, u_catalog,
  u_corpus_manifest, u_corpus_reader, u_corpus_store, u_corpus_installer;

// ============================================================================
// SCHEMA HELPERS
// ============================================================================

function MakeStringArrayProp(const ADesc: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'array');
  Result.Add('description', ADesc);
  Result.Add('items', MakeStringProp('Corpus ID'));
end;

// ============================================================================
// SCHEMA
// ============================================================================

function BuildToolSchema_Setup: TJSONObject;
var
  Schema, Props, ActionProp: TJSONObject;
  Required, ActionEnum: TJSONArray;
begin
  ActionEnum := TJSONArray.Create;
  ActionEnum.Add('status');
  ActionEnum.Add('list_available');
  ActionEnum.Add('install_bundled');
  ActionEnum.Add('download_arabic');
  ActionEnum.Add('download');

  ActionProp := TJSONObject.Create;
  ActionProp.Add('type', 'string');
  ActionProp.Add('description',
    'Action to perform. "status": check setup state. ' +
    '"list_available": list catalog translations. ' +
    '"install_bundled": install bundled public-domain translations. ' +
    '"download_arabic": download Arabic base text corpus. ' +
    '"download": download one or more translations by ID.');
  ActionProp.Add('enum', ActionEnum);

  Props := TJSONObject.Create;
  Props.Add('action', ActionProp);
  Props.Add('lang', MakeStringProp(
    'Language filter for list_available (e.g. "en"). Optional.'));
  Props.Add('ids', MakeStringArrayProp(
    'Array of corpus IDs to download. Required for "download" action.'));
  Props.Add('arabic_id', MakeStringProp(
    'Arabic corpus ID to download. Default: "ar.uthmani". ' +
    'Used with "download_arabic" action.'));

  Required := TJSONArray.Create;
  Required.Add('action');

  Schema := TJSONObject.Create;
  Schema.Add('type', 'object');
  Schema.Add('properties', Props);
  Schema.Add('required', Required);

  Result := TJSONObject.Create;
  Result.Add('name', 'quran.setup');
  Result.Add('description',
    'First-run setup and corpus management. Install bundled translations, ' +
    'download Arabic text and additional translations, check setup status, ' +
    'or browse the translation catalog.');
  Result.Add('inputSchema', Schema);
end;

// ============================================================================
// ACTION HANDLERS
// ============================================================================

function HandleSetupStatus(const AReq: TJsonRpcRequest): TJSONObject;
var
  ResObj: TJSONObject;
  HasArabic: Boolean;
  I: Integer;
  Store: PVerseStore;
begin
  // Check if Arabic is installed
  HasArabic := False;
  for I := 0 to GetCorpusCount - 1 do
  begin
    Store := GetCorpusByIndex(I);
    if (Store <> nil) and (Store^.Manifest.Kind = ckArabic) then
    begin
      HasArabic := True;
      Break;
    end;
  end;

  ResObj := TJSONObject.Create;
  ResObj.Add('setup_completed', (GetCorpusCount > 0));
  ResObj.Add('arabic_installed', HasArabic);
  ResObj.Add('bundled_installed', (GetCorpusCount >= GetBundledCount) and
    (GetBundledCount > 0));
  ResObj.Add('installed_count', GetCorpusCount);
  if IsCatalogLoaded then
    ResObj.Add('available_count', GetCatalogCount)
  else
    ResObj.Add('available_count', 0);
  ResObj.Add('data_root', GetDataRoot);

  Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
  ResObj.Free;
end;

function HandleSetupListAvailable(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;
var
  LangFilter: String;
  CatalogArr: TJSONArray;
  ResObj: TJSONObject;
begin
  if not IsCatalogLoaded then
  begin
    Result := BuildToolError(AReq, ERR_SETUP_INCOMPLETE,
      'Catalog not loaded. Ensure catalog/translations.json is accessible.');
    Exit;
  end;

  LangFilter := '';
  if AArgs <> nil then
    LangFilter := AArgs.Get('lang', '');

  CatalogArr := BuildCatalogListJson(LangFilter);

  ResObj := TJSONObject.Create;
  ResObj.Add('count', CatalogArr.Count);
  ResObj.Add('translations', CatalogArr);

  Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
  ResObj.Free;
end;

function HandleSetupInstallBundled(const AReq: TJsonRpcRequest): TJSONObject;
var
  BPath: String;
  Report: TInstallReport;
  ResObj: TJSONObject;
  InstalledArr, SkippedArr, ErrorArr: TJSONArray;
  ErrObj: TJSONObject;
  I: Integer;
begin
  BPath := GetBundledPath;
  if BPath = '' then
  begin
    Result := BuildToolError(AReq, ERR_SETUP_INCOMPLETE,
      'Bundled path not configured. Cannot install bundled corpora.');
    Exit;
  end;

  if not DirectoryExists(BPath) then
  begin
    Result := BuildToolError(AReq, ERR_SETUP_INCOMPLETE,
      'Bundled directory not found: ' + BPath);
    Exit;
  end;

  Report := InstallBundledCorpora(BPath, GetDataRoot);

  // Re-scan corpus store if anything was installed
  if Length(Report.Installed) > 0 then
    InitCorpusStore(GetDataRoot);

  // Build response
  InstalledArr := TJSONArray.Create;
  for I := 0 to High(Report.Installed) do
    InstalledArr.Add(Report.Installed[I]);

  SkippedArr := TJSONArray.Create;
  for I := 0 to High(Report.Skipped) do
    SkippedArr.Add(Report.Skipped[I]);

  ErrorArr := TJSONArray.Create;
  for I := 0 to High(Report.Errors) do
  begin
    ErrObj := TJSONObject.Create;
    ErrObj.Add('corpus_id', Report.Errors[I].CorpusId);
    ErrObj.Add('error', Report.Errors[I].ErrorMsg);
    ErrorArr.Add(ErrObj);
  end;

  ResObj := TJSONObject.Create;
  ResObj.Add('installed_count', Length(Report.Installed));
  ResObj.Add('skipped_count', Length(Report.Skipped));
  ResObj.Add('error_count', Length(Report.Errors));
  ResObj.Add('installed', InstalledArr);
  ResObj.Add('skipped', SkippedArr);
  ResObj.Add('errors', ErrorArr);

  Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
  ResObj.Free;
end;

function HandleSetupDownloadArabic(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;
var
  ArabicId: String;
  Entry: PCatalogEntry;
  Skipped: Boolean;
  ErrMsg: String;
  ResObj: TJSONObject;
begin
  if not IsCatalogLoaded then
  begin
    Result := BuildToolError(AReq, ERR_SETUP_INCOMPLETE,
      'Catalog not loaded. Cannot download Arabic corpus.');
    Exit;
  end;

  // Determine which Arabic corpus to download
  ArabicId := 'ar.uthmani';
  if (AArgs <> nil) and (AArgs.Get('arabic_id', '') <> '') then
    ArabicId := AArgs.Get('arabic_id', '');

  // Look up in catalog (Arabic entries)
  Entry := FindArabicEntry(ArabicId);
  if Entry = nil then
    Entry := FindCatalogEntry(ArabicId);
  if Entry = nil then
  begin
    Result := BuildToolError(AReq, ERR_CATALOG_ID_UNKNOWN,
      'Arabic corpus not found in catalog: ' + ArabicId);
    Exit;
  end;

  Skipped := False;
  ErrMsg := '';
  if not DownloadAndInstallCatalogEntry(Entry, GetDataRoot, Skipped, ErrMsg) then
  begin
    Result := BuildToolError(AReq, ERR_DOWNLOAD_FAILED,
      'Failed to download ' + ArabicId + ': ' + ErrMsg);
    Exit;
  end;

  // Re-scan corpus store
  if not Skipped then
    InitCorpusStore(GetDataRoot);

  ResObj := TJSONObject.Create;
  ResObj.Add('id', ArabicId);
  if Skipped then
    ResObj.Add('status', 'already_installed')
  else
    ResObj.Add('status', 'installed');
  ResObj.Add('installed_count', GetCorpusCount);

  Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
  ResObj.Free;
end;

function HandleSetupDownload(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;
var
  IdsArr: TJSONArray;
  I: Integer;
  CorpusId, ErrMsg: String;
  Entry: PCatalogEntry;
  Skipped: Boolean;
  ResObj: TJSONObject;
  ResultsArr: TJSONArray;
  ItemObj: TJSONObject;
  InstalledCount, SkippedCount, ErrorCount: Integer;
  AnyInstalled: Boolean;
begin
  if AArgs = nil then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing arguments for download action');
    Exit;
  end;

  // ids parameter is required
  if (AArgs.IndexOfName('ids') < 0) or
     not (AArgs.Elements['ids'] is TJSONArray) then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing required parameter: ids (array of corpus IDs)');
    Exit;
  end;

  if not IsCatalogLoaded then
  begin
    Result := BuildToolError(AReq, ERR_SETUP_INCOMPLETE,
      'Catalog not loaded. Cannot download translations.');
    Exit;
  end;

  IdsArr := AArgs.Arrays['ids'];
  InstalledCount := 0;
  SkippedCount := 0;
  ErrorCount := 0;
  AnyInstalled := False;
  ResultsArr := TJSONArray.Create;

  for I := 0 to IdsArr.Count - 1 do
  begin
    CorpusId := IdsArr.Strings[I];

    // Look up in catalog
    Entry := FindCatalogEntry(CorpusId);
    if Entry = nil then
    begin
      ItemObj := TJSONObject.Create;
      ItemObj.Add('id', CorpusId);
      ItemObj.Add('status', 'error');
      ItemObj.Add('error', 'Not found in catalog');
      ResultsArr.Add(ItemObj);
      Inc(ErrorCount);
      Continue;
    end;

    Skipped := False;
    ErrMsg := '';
    if DownloadAndInstallCatalogEntry(Entry, GetDataRoot, Skipped, ErrMsg) then
    begin
      ItemObj := TJSONObject.Create;
      ItemObj.Add('id', CorpusId);
      if Skipped then
      begin
        ItemObj.Add('status', 'already_installed');
        Inc(SkippedCount);
      end
      else
      begin
        ItemObj.Add('status', 'installed');
        Inc(InstalledCount);
        AnyInstalled := True;
      end;
      ResultsArr.Add(ItemObj);
    end
    else
    begin
      ItemObj := TJSONObject.Create;
      ItemObj.Add('id', CorpusId);
      ItemObj.Add('status', 'error');
      ItemObj.Add('error', ErrMsg);
      ResultsArr.Add(ItemObj);
      Inc(ErrorCount);
    end;
  end;

  // Re-scan corpus store if anything was installed
  if AnyInstalled then
    InitCorpusStore(GetDataRoot);

  ResObj := TJSONObject.Create;
  ResObj.Add('installed_count', InstalledCount);
  ResObj.Add('skipped_count', SkippedCount);
  ResObj.Add('error_count', ErrorCount);
  ResObj.Add('results', ResultsArr);

  Result := BuildToolResult(AReq, MakeTextContent(ResObj.AsJSON));
  ResObj.Free;
end;

// ============================================================================
// MAIN DISPATCHER
// ============================================================================

function HandleSetup(const AReq: TJsonRpcRequest;
  AArgs: TJSONObject): TJSONObject;
var
  Action: String;
begin
  if AArgs = nil then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing arguments for quran.setup');
    Exit;
  end;

  Action := AArgs.Get('action', '');
  if Action = '' then
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Missing required parameter: action');
    Exit;
  end;

  LogInfo('quran.setup action=' + Action);

  if Action = 'status' then
    Result := HandleSetupStatus(AReq)
  else if Action = 'list_available' then
    Result := HandleSetupListAvailable(AReq, AArgs)
  else if Action = 'install_bundled' then
    Result := HandleSetupInstallBundled(AReq)
  else if Action = 'download_arabic' then
    Result := HandleSetupDownloadArabic(AReq, AArgs)
  else if Action = 'download' then
    Result := HandleSetupDownload(AReq, AArgs)
  else
  begin
    Result := BuildToolError(AReq, JSONRPC_INVALID_PARAMS,
      'Unknown setup action: ' + Action);
  end;
end;

end.
