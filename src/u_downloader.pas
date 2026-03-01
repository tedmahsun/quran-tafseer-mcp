unit u_downloader;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

/// Check if a URL is allowed by the domain allowlist.
/// Only HTTPS URLs to allowed domains are permitted.
function IsUrlAllowed(const AUrl: String; out AError: String): Boolean;

/// Download a URL into a TMemoryStream.
/// On Windows uses WinINet (native TLS). Elsewhere uses fphttpclient + OpenSSL.
/// Caller must free AData on success.
function DownloadUrl(const AUrl: String; out AData: TMemoryStream;
  out AError: String): Boolean;

/// Compute SHA-256 hash of a stream, returning 64-char lowercase hex string.
function ComputeSha256Hex(AStream: TStream): String;

/// Download a URL and optionally verify its SHA-256 checksum.
/// If AExpectedChecksum is empty, checksum verification is skipped.
/// AExpectedChecksum may be a raw hex string or prefixed with "sha256:".
/// Caller must free AData on success.
function DownloadAndVerify(const AUrl, AExpectedChecksum: String;
  out AData: TMemoryStream; out AError: String): Boolean;

implementation

uses
  {$IFDEF MSWINDOWS}
  Windows,
  {$ELSE}
  fphttpclient, opensslsockets,
  {$ENDIF}
  u_log;

// ============================================================================
// DOMAIN ALLOWLIST
// ============================================================================

const
  ALLOWED_DOMAINS: array[0..3] of String = (
    'cdn.jsdelivr.net',
    'tanzil.net',
    'qul.tarteel.ai',
    'quranenc.com'
  );

function ExtractHostFromUrl(const AUrl: String): String;
var
  Start, Finish: Integer;
begin
  Result := '';
  Start := Pos('://', AUrl);
  if Start = 0 then
    Exit;
  Start := Start + 3;
  Finish := Start;
  while (Finish <= Length(AUrl)) and
        (AUrl[Finish] <> '/') and (AUrl[Finish] <> ':') do
    Inc(Finish);
  Result := LowerCase(Copy(AUrl, Start, Finish - Start));
end;

function IsUrlAllowed(const AUrl: String; out AError: String): Boolean;
var
  Host: String;
  I: Integer;
begin
  Result := False;
  AError := '';

  if Pos('https://', LowerCase(AUrl)) <> 1 then
  begin
    AError := 'Only HTTPS URLs are allowed';
    Exit;
  end;

  Host := ExtractHostFromUrl(AUrl);
  if Host = '' then
  begin
    AError := 'Cannot extract hostname from URL';
    Exit;
  end;

  for I := Low(ALLOWED_DOMAINS) to High(ALLOWED_DOMAINS) do
  begin
    if Host = ALLOWED_DOMAINS[I] then
    begin
      Result := True;
      Exit;
    end;
  end;

  AError := 'Domain "' + Host + '" is not in the allowlist';
end;

// ============================================================================
// SHA-256 IMPLEMENTATION (self-contained, FPC 3.2.2 lacks fpsha256)
// ============================================================================

type
  TSha256State = array[0..7] of DWord;

const
  SHA256_K: array[0..63] of DWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5,
    $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3,
    $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc,
    $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7,
    $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13,
    $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3,
    $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5,
    $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208,
    $90befffa, $a4506ceb, $bef9a3f7, $c67178f2
  );

  SHA256_INIT: array[0..7] of DWord = (
    $6a09e667, $bb67ae85, $3c6ef372, $a54ff53a,
    $510e527f, $9b05688c, $1f83d9ab, $5be0cd19
  );

function RightRotate(AValue: DWord; AShift: Integer): DWord; inline;
begin
  Result := (AValue shr AShift) or (AValue shl (32 - AShift));
end;

procedure Sha256Transform(var AState: TSha256State;
  const ABlock: array of Byte);
var
  W: array[0..63] of DWord;
  A, B, C, D, E, F, G, H: DWord;
  S0, S1, Ch, Temp1, Temp2, Maj: DWord;
  I: Integer;
begin
  // Prepare message schedule from 16 big-endian DWords
  for I := 0 to 15 do
    W[I] := (DWord(ABlock[I * 4]) shl 24) or
            (DWord(ABlock[I * 4 + 1]) shl 16) or
            (DWord(ABlock[I * 4 + 2]) shl 8) or
             DWord(ABlock[I * 4 + 3]);

  for I := 16 to 63 do
  begin
    S0 := RightRotate(W[I-15], 7) xor RightRotate(W[I-15], 18) xor
          (W[I-15] shr 3);
    S1 := RightRotate(W[I-2], 17) xor RightRotate(W[I-2], 19) xor
          (W[I-2] shr 10);
    W[I] := W[I-16] + S0 + W[I-7] + S1;
  end;

  A := AState[0]; B := AState[1]; C := AState[2]; D := AState[3];
  E := AState[4]; F := AState[5]; G := AState[6]; H := AState[7];

  for I := 0 to 63 do
  begin
    S1 := RightRotate(E, 6) xor RightRotate(E, 11) xor RightRotate(E, 25);
    Ch := (E and F) xor ((not E) and G);
    Temp1 := H + S1 + Ch + SHA256_K[I] + W[I];
    S0 := RightRotate(A, 2) xor RightRotate(A, 13) xor RightRotate(A, 22);
    Maj := (A and B) xor (A and C) xor (B and C);
    Temp2 := S0 + Maj;

    H := G; G := F; F := E; E := D + Temp1;
    D := C; C := B; B := A; A := Temp1 + Temp2;
  end;

  AState[0] := AState[0] + A;
  AState[1] := AState[1] + B;
  AState[2] := AState[2] + C;
  AState[3] := AState[3] + D;
  AState[4] := AState[4] + E;
  AState[5] := AState[5] + F;
  AState[6] := AState[6] + G;
  AState[7] := AState[7] + H;
end;

function ComputeSha256Hex(AStream: TStream): String;
var
  State: TSha256State;
  Block: array[0..63] of Byte;
  TotalLen: QWord;
  BytesRead, Remaining, I: Integer;
  BitLen: QWord;
begin
  for I := 0 to 7 do
    State[I] := SHA256_INIT[I];

  AStream.Position := 0;
  TotalLen := 0;

  // Process complete 64-byte blocks
  repeat
    BytesRead := AStream.Read(Block, 64);
    if BytesRead = 64 then
    begin
      Sha256Transform(State, Block);
      TotalLen := TotalLen + 64;
    end;
  until BytesRead < 64;

  TotalLen := TotalLen + QWord(BytesRead);
  BitLen := TotalLen * 8;

  // Pad the final partial block
  Remaining := BytesRead;
  Block[Remaining] := $80;
  Inc(Remaining);

  // Zero-fill
  if Remaining > 56 then
  begin
    while Remaining < 64 do
    begin
      Block[Remaining] := 0;
      Inc(Remaining);
    end;
    Sha256Transform(State, Block);
    Remaining := 0;
  end;

  while Remaining < 56 do
  begin
    Block[Remaining] := 0;
    Inc(Remaining);
  end;

  // Append bit length as big-endian 64-bit
  Block[56] := Byte(BitLen shr 56);
  Block[57] := Byte(BitLen shr 48);
  Block[58] := Byte(BitLen shr 40);
  Block[59] := Byte(BitLen shr 32);
  Block[60] := Byte(BitLen shr 24);
  Block[61] := Byte(BitLen shr 16);
  Block[62] := Byte(BitLen shr 8);
  Block[63] := Byte(BitLen);

  Sha256Transform(State, Block);

  // Produce 64-char lowercase hex digest
  Result := LowerCase(
    IntToHex(State[0], 8) + IntToHex(State[1], 8) +
    IntToHex(State[2], 8) + IntToHex(State[3], 8) +
    IntToHex(State[4], 8) + IntToHex(State[5], 8) +
    IntToHex(State[6], 8) + IntToHex(State[7], 8)
  );
end;

// ============================================================================
// HTTP DOWNLOAD — PLATFORM-SPECIFIC
// ============================================================================

{$IFDEF MSWINDOWS}

// Minimal WinINet declarations — avoids needing the full WinINet unit
const
  WININET_DLL = 'wininet.dll';
  INTERNET_OPEN_TYPE_PRECONFIG = 0;
  INTERNET_FLAG_RELOAD         = DWORD($80000000);
  HTTP_QUERY_STATUS_CODE       = 19;
  HTTP_QUERY_FLAG_NUMBER       = DWORD($20000000);

type
  HINTERNET = Pointer;

function WinInet_InternetOpenA(Agent: PAnsiChar; AccessType: DWORD;
  Proxy, ProxyBypass: PAnsiChar; Flags: DWORD): HINTERNET;
  stdcall; external WININET_DLL name 'InternetOpenA';

function WinInet_InternetOpenUrlA(hSession: HINTERNET; Url: PAnsiChar;
  Headers: PAnsiChar; HeadersLen: DWORD; Flags: DWORD;
  Context: PtrUInt): HINTERNET;
  stdcall; external WININET_DLL name 'InternetOpenUrlA';

function WinInet_InternetReadFile(hFile: HINTERNET; Buffer: Pointer;
  BytesToRead: DWORD; var BytesRead: DWORD): BOOL;
  stdcall; external WININET_DLL name 'InternetReadFile';

function WinInet_InternetCloseHandle(hInet: HINTERNET): BOOL;
  stdcall; external WININET_DLL name 'InternetCloseHandle';

function WinInet_HttpQueryInfoA(hRequest: HINTERNET; InfoLevel: DWORD;
  Buffer: Pointer; var BufLen: DWORD; Index: Pointer): BOOL;
  stdcall; external WININET_DLL name 'HttpQueryInfoA';

function GetWinInetStatusCode(hUrl: HINTERNET): DWORD;
var
  Code, BufLen: DWORD;
begin
  Code := 0;
  BufLen := SizeOf(Code);
  WinInet_HttpQueryInfoA(hUrl,
    HTTP_QUERY_STATUS_CODE or HTTP_QUERY_FLAG_NUMBER,
    @Code, BufLen, nil);
  Result := Code;
end;

function DownloadUrl(const AUrl: String; out AData: TMemoryStream;
  out AError: String): Boolean;
var
  hSession, hUrl: HINTERNET;
  Buffer: array[0..8191] of Byte;
  BytesRead: DWORD;
  StatusCode: DWORD;
  UrlErr: String;
begin
  Result := False;
  AData := nil;
  AError := '';

  if not IsUrlAllowed(AUrl, UrlErr) then
  begin
    AError := UrlErr;
    Exit;
  end;

  hSession := WinInet_InternetOpenA('quran-tafseer-mcp/1.0.0',
    INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0);
  if hSession = nil then
  begin
    AError := 'WinINet: InternetOpen failed (error ' +
      IntToStr(GetLastError) + ')';
    Exit;
  end;

  try
    LogInfo('Downloading: ' + AUrl);
    hUrl := WinInet_InternetOpenUrlA(hSession, PAnsiChar(AnsiString(AUrl)),
      nil, 0, INTERNET_FLAG_RELOAD, 0);
    if hUrl = nil then
    begin
      AError := 'WinINet: Failed to open URL (error ' +
        IntToStr(GetLastError) + ')';
      Exit;
    end;

    try
      // Check HTTP status
      StatusCode := GetWinInetStatusCode(hUrl);
      if (StatusCode <> 0) and (StatusCode <> 200) then
      begin
        AError := 'HTTP ' + IntToStr(StatusCode) + ' for ' + AUrl;
        Exit;
      end;

      AData := TMemoryStream.Create;
      repeat
        BytesRead := 0;
        if not WinInet_InternetReadFile(hUrl, @Buffer,
          SizeOf(Buffer), BytesRead) then
        begin
          AError := 'WinINet: Read error (error ' +
            IntToStr(GetLastError) + ')';
          FreeAndNil(AData);
          Exit;
        end;
        if BytesRead > 0 then
          AData.Write(Buffer, BytesRead);
      until BytesRead = 0;

      AData.Position := 0;
      LogInfo('Downloaded ' + IntToStr(AData.Size) + ' bytes from ' + AUrl);
      Result := True;
    finally
      WinInet_InternetCloseHandle(hUrl);
    end;
  finally
    WinInet_InternetCloseHandle(hSession);
  end;
end;

{$ELSE}

// Non-Windows: use fphttpclient + opensslsockets (OpenSSL is a system lib
// on Linux; on macOS install via Homebrew if needed)

function DownloadUrl(const AUrl: String; out AData: TMemoryStream;
  out AError: String): Boolean;
var
  Client: TFPHTTPClient;
  UrlErr: String;
begin
  Result := False;
  AData := nil;
  AError := '';

  if not IsUrlAllowed(AUrl, UrlErr) then
  begin
    AError := UrlErr;
    Exit;
  end;

  AData := TMemoryStream.Create;
  Client := TFPHTTPClient.Create(nil);
  try
    Client.AllowRedirect := True;
    Client.ConnectTimeout := 30000;
    Client.IOTimeout := 60000;

    LogInfo('Downloading: ' + AUrl);
    try
      Client.Get(AUrl, AData);
    except
      on E: Exception do
      begin
        AError := 'Download failed: ' + E.Message;
        FreeAndNil(AData);
        Exit;
      end;
    end;

    if Client.ResponseStatusCode <> 200 then
    begin
      AError := 'HTTP ' + IntToStr(Client.ResponseStatusCode) +
        ' for ' + AUrl;
      FreeAndNil(AData);
      Exit;
    end;

    AData.Position := 0;
    LogInfo('Downloaded ' + IntToStr(AData.Size) + ' bytes from ' + AUrl);
    Result := True;
  finally
    Client.Free;
  end;
end;

{$ENDIF}

// ============================================================================
// DOWNLOAD + VERIFY
// ============================================================================

function DownloadAndVerify(const AUrl, AExpectedChecksum: String;
  out AData: TMemoryStream; out AError: String): Boolean;
var
  ActualHash, ExpectedHash: String;
begin
  Result := False;

  if not DownloadUrl(AUrl, AData, AError) then
    Exit;

  if AExpectedChecksum <> '' then
  begin
    ActualHash := ComputeSha256Hex(AData);
    AData.Position := 0;

    // Normalize: strip "sha256:" prefix if present
    ExpectedHash := AExpectedChecksum;
    if Pos('sha256:', ExpectedHash) = 1 then
      ExpectedHash := Copy(ExpectedHash, 8, Length(ExpectedHash));
    ExpectedHash := LowerCase(ExpectedHash);

    if ActualHash <> ExpectedHash then
    begin
      AError := 'Checksum mismatch: expected ' + ExpectedHash +
        ', got ' + ActualHash;
      FreeAndNil(AData);
      Exit;
    end;
    LogInfo('Checksum verified: ' + ActualHash);
  end
  else
    LogDebug('No checksum provided, skipping verification');

  Result := True;
end;

end.
