unit u_quran_metadata;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

type
  TRevelationPlace = (rpMeccan, rpMedinan);

  TSurahInfo = record
    Number: Byte;
    ArabicName: String;
    TranslitName: String;
    EnglishMeaning: String;
    AyahCount: Word;
    RevelationOrder: Byte;
    RevelationPlace: TRevelationPlace;
  end;
  PSurahInfo = ^TSurahInfo;

  TSurahAlias = record
    SurahNumber: Byte;
    Alias: String;
  end;

const
  SURAH_COUNT = 114;
  TOTAL_AYAH_COUNT = 6236;

var
  SurahData: array[1..114] of TSurahInfo;

function GetSurahByNumber(ANumber: Integer): PSurahInfo;
function FindSurahByName(const AName: String): Integer;
function IsValidReference(ASurah, AAyah: Integer): Boolean;
function GetAyahCount(ASurah: Integer): Integer;

implementation

uses
  SysUtils;

const
  SURAH_ALIASES: array[0..71] of TSurahAlias = (
    // Common alternate transliterations and short names
    (SurahNumber: 1;  Alias: 'fatiha'),
    (SurahNumber: 1;  Alias: 'fateha'),
    (SurahNumber: 1;  Alias: 'opening'),
    (SurahNumber: 2;  Alias: 'baqara'),
    (SurahNumber: 2;  Alias: 'bakara'),
    (SurahNumber: 3;  Alias: 'imran'),
    (SurahNumber: 3;  Alias: 'aal imran'),
    (SurahNumber: 3;  Alias: 'ale imran'),
    (SurahNumber: 4;  Alias: 'nisa'),
    (SurahNumber: 4;  Alias: 'nisaa'),
    (SurahNumber: 5;  Alias: 'maida'),
    (SurahNumber: 5;  Alias: 'maidah'),
    (SurahNumber: 7;  Alias: 'araf'),
    (SurahNumber: 9;  Alias: 'tawba'),
    (SurahNumber: 9;  Alias: 'taubah'),
    (SurahNumber: 9;  Alias: 'bara''ah'),
    (SurahNumber: 12; Alias: 'joseph'),
    (SurahNumber: 14; Alias: 'abraham'),
    (SurahNumber: 16; Alias: 'nahl'),
    (SurahNumber: 17; Alias: 'isra'),
    (SurahNumber: 17; Alias: 'bani israil'),
    (SurahNumber: 18; Alias: 'kahf'),
    (SurahNumber: 19; Alias: 'mary'),
    (SurahNumber: 20; Alias: 'ta ha'),
    (SurahNumber: 21; Alias: 'anbiya'),
    (SurahNumber: 22; Alias: 'hajj'),
    (SurahNumber: 23; Alias: 'muminun'),
    (SurahNumber: 23; Alias: 'muminoon'),
    (SurahNumber: 24; Alias: 'nur'),
    (SurahNumber: 24; Alias: 'noor'),
    (SurahNumber: 25; Alias: 'furqan'),
    (SurahNumber: 26; Alias: 'shuara'),
    (SurahNumber: 27; Alias: 'naml'),
    (SurahNumber: 28; Alias: 'qasas'),
    (SurahNumber: 29; Alias: 'ankabut'),
    (SurahNumber: 30; Alias: 'rum'),
    (SurahNumber: 33; Alias: 'ahzab'),
    (SurahNumber: 34; Alias: 'saba'),
    (SurahNumber: 34; Alias: 'sheba'),
    (SurahNumber: 36; Alias: 'yasin'),
    (SurahNumber: 36; Alias: 'yaseen'),
    (SurahNumber: 37; Alias: 'saffat'),
    (SurahNumber: 38; Alias: 'saad'),
    (SurahNumber: 40; Alias: 'mumin'),
    (SurahNumber: 40; Alias: 'mu''min'),
    (SurahNumber: 47; Alias: 'mohammed'),
    (SurahNumber: 48; Alias: 'fath'),
    (SurahNumber: 49; Alias: 'hujurat'),
    (SurahNumber: 50; Alias: 'qaaf'),
    (SurahNumber: 55; Alias: 'rahman'),
    (SurahNumber: 55; Alias: 'ar rahman'),
    (SurahNumber: 56; Alias: 'waqiah'),
    (SurahNumber: 56; Alias: 'waqia'),
    (SurahNumber: 57; Alias: 'hadid'),
    (SurahNumber: 67; Alias: 'mulk'),
    (SurahNumber: 68; Alias: 'qalam'),
    (SurahNumber: 71; Alias: 'noah'),
    (SurahNumber: 72; Alias: 'jinn'),
    (SurahNumber: 73; Alias: 'muzzammil'),
    (SurahNumber: 74; Alias: 'muddathir'),
    (SurahNumber: 74; Alias: 'muddaththir'),
    (SurahNumber: 75; Alias: 'qiyama'),
    (SurahNumber: 75; Alias: 'qiyamah'),
    (SurahNumber: 78; Alias: 'naba'),
    (SurahNumber: 87; Alias: 'ala'),
    (SurahNumber: 96; Alias: 'alaq'),
    (SurahNumber: 97; Alias: 'qadr'),
    (SurahNumber: 108; Alias: 'kauthar'),
    (SurahNumber: 108; Alias: 'kawthar'),
    (SurahNumber: 109; Alias: 'kafirun'),
    (SurahNumber: 112; Alias: 'ikhlas'),
    (SurahNumber: 113; Alias: 'falaq')
  );

function StripSurahPrefix(const AName: String): String;
var
  S: String;
begin
  S := LowerCase(AName);
  S := Trim(S);
  if Copy(S, 1, 6) = 'surah ' then
    Result := Trim(Copy(S, 7, Length(S)))
  else if Copy(S, 1, 5) = 'sura ' then
    Result := Trim(Copy(S, 6, Length(S)))
  else if Copy(S, 1, 7) = 'suratul' then
  begin
    // Handle "suratul-baqarah", "suratul baqarah"
    if (Length(S) > 7) and ((S[8] = '-') or (S[8] = ' ')) then
      Result := Trim(Copy(S, 9, Length(S)))
    else
      Result := Trim(Copy(S, 8, Length(S)));
  end
  else if Copy(S, 1, 5) = 'surat' then
  begin
    // Handle "surat " and "suratu" etc.
    if (Length(S) > 5) and ((S[6] = ' ') or (S[6] = '-')) then
      Result := Trim(Copy(S, 7, Length(S)))
    else
      Result := S;
  end
  else
    Result := S;
end;

function GetSurahByNumber(ANumber: Integer): PSurahInfo;
begin
  if (ANumber < 1) or (ANumber > SURAH_COUNT) then
    Result := nil
  else
    Result := @SurahData[ANumber];
end;

function FindSurahByName(const AName: String): Integer;
var
  Needle: String;
  I: Integer;
begin
  Result := 0;
  if AName = '' then
    Exit;

  // Try numeric first
  I := StrToIntDef(AName, 0);
  if (I >= 1) and (I <= SURAH_COUNT) then
  begin
    Result := I;
    Exit;
  end;

  Needle := StripSurahPrefix(AName);

  // Check transliterated names (case-insensitive)
  for I := 1 to SURAH_COUNT do
  begin
    if LowerCase(SurahData[I].TranslitName) = Needle then
    begin
      Result := I;
      Exit;
    end;
  end;

  // Check English meanings (case-insensitive)
  for I := 1 to SURAH_COUNT do
  begin
    if LowerCase(SurahData[I].EnglishMeaning) = Needle then
    begin
      Result := I;
      Exit;
    end;
  end;

  // Check Arabic names
  for I := 1 to SURAH_COUNT do
  begin
    if SurahData[I].ArabicName = AName then
    begin
      Result := I;
      Exit;
    end;
  end;

  // Check aliases
  for I := Low(SURAH_ALIASES) to High(SURAH_ALIASES) do
  begin
    if SURAH_ALIASES[I].Alias = Needle then
    begin
      Result := SURAH_ALIASES[I].SurahNumber;
      Exit;
    end;
  end;

  // Partial match on transliterated names (starts with)
  for I := 1 to SURAH_COUNT do
  begin
    if Pos(Needle, LowerCase(SurahData[I].TranslitName)) = 1 then
    begin
      Result := I;
      Exit;
    end;
  end;
end;

function IsValidReference(ASurah, AAyah: Integer): Boolean;
begin
  Result := (ASurah >= 1) and (ASurah <= SURAH_COUNT) and
            (AAyah >= 1) and (AAyah <= SurahData[ASurah].AyahCount);
end;

function GetAyahCount(ASurah: Integer): Integer;
begin
  if (ASurah < 1) or (ASurah > SURAH_COUNT) then
    Result := 0
  else
    Result := SurahData[ASurah].AyahCount;
end;

procedure InitSurahData;

  procedure S(ANum: Byte; const AArabic, ATranslit, AEnglish: String;
    AAyahCount: Word; ARevOrder: Byte; APlace: TRevelationPlace);
  begin
    SurahData[ANum].Number := ANum;
    SurahData[ANum].ArabicName := AArabic;
    SurahData[ANum].TranslitName := ATranslit;
    SurahData[ANum].EnglishMeaning := AEnglish;
    SurahData[ANum].AyahCount := AAyahCount;
    SurahData[ANum].RevelationOrder := ARevOrder;
    SurahData[ANum].RevelationPlace := APlace;
  end;

begin
  S(  1, 'الفاتحة',    'Al-Fatihah',       'The Opener',                     7,   5, rpMeccan);
  S(  2, 'البقرة',     'Al-Baqarah',       'The Cow',                      286,  87, rpMedinan);
  S(  3, 'آل عمران',   'Ali ''Imran',      'Family of Imran',              200,  89, rpMedinan);
  S(  4, 'النساء',     'An-Nisa',          'The Women',                    176,  92, rpMedinan);
  S(  5, 'المائدة',    'Al-Ma''idah',      'The Table Spread',             120, 112, rpMedinan);
  S(  6, 'الأنعام',    'Al-An''am',        'The Cattle',                   165,  55, rpMeccan);
  S(  7, 'الأعراف',    'Al-A''raf',        'The Heights',                  206,  39, rpMeccan);
  S(  8, 'الأنفال',    'Al-Anfal',         'The Spoils of War',             75,  88, rpMedinan);
  S(  9, 'التوبة',     'At-Tawbah',        'The Repentance',               129, 113, rpMedinan);
  S( 10, 'يونس',       'Yunus',            'Jonah',                        109,  51, rpMeccan);
  S( 11, 'هود',        'Hud',              'Hud',                          123,  52, rpMeccan);
  S( 12, 'يوسف',       'Yusuf',            'Joseph',                       111,  53, rpMeccan);
  S( 13, 'الرعد',      'Ar-Ra''d',         'The Thunder',                   43,  96, rpMedinan);
  S( 14, 'ابراهيم',    'Ibrahim',          'Abraham',                       52,  72, rpMeccan);
  S( 15, 'الحجر',      'Al-Hijr',          'The Rocky Tract',               99,  54, rpMeccan);
  S( 16, 'النحل',      'An-Nahl',          'The Bee',                      128,  70, rpMeccan);
  S( 17, 'الإسراء',    'Al-Isra',          'The Night Journey',            111,  50, rpMeccan);
  S( 18, 'الكهف',      'Al-Kahf',          'The Cave',                     110,  69, rpMeccan);
  S( 19, 'مريم',       'Maryam',           'Mary',                          98,  44, rpMeccan);
  S( 20, 'طه',         'Taha',             'Ta-Ha',                        135,  45, rpMeccan);
  S( 21, 'الأنبياء',   'Al-Anbya',         'The Prophets',                 112,  73, rpMeccan);
  S( 22, 'الحج',       'Al-Hajj',          'The Pilgrimage',                78, 103, rpMedinan);
  S( 23, 'المؤمنون',   'Al-Mu''minun',     'The Believers',                118,  74, rpMeccan);
  S( 24, 'النور',      'An-Nur',           'The Light',                     64, 102, rpMedinan);
  S( 25, 'الفرقان',    'Al-Furqan',        'The Criterion',                 77,  42, rpMeccan);
  S( 26, 'الشعراء',    'Ash-Shu''ara',     'The Poets',                    227,  47, rpMeccan);
  S( 27, 'النمل',      'An-Naml',          'The Ant',                       93,  48, rpMeccan);
  S( 28, 'القصص',      'Al-Qasas',         'The Stories',                   88,  49, rpMeccan);
  S( 29, 'العنكبوت',   'Al-''Ankabut',     'The Spider',                    69,  85, rpMeccan);
  S( 30, 'الروم',      'Ar-Rum',           'The Romans',                    60,  84, rpMeccan);
  S( 31, 'لقمان',      'Luqman',           'Luqman',                        34,  57, rpMeccan);
  S( 32, 'السجدة',     'As-Sajdah',        'The Prostration',               30,  75, rpMeccan);
  S( 33, 'الأحزاب',    'Al-Ahzab',         'The Combined Forces',           73,  90, rpMedinan);
  S( 34, 'سبإ',        'Saba',             'Sheba',                         54,  58, rpMeccan);
  S( 35, 'فاطر',       'Fatir',            'Originator',                    45,  43, rpMeccan);
  S( 36, 'يس',         'Ya-Sin',           'Ya Sin',                        83,  41, rpMeccan);
  S( 37, 'الصافات',    'As-Saffat',        'Those Who Set the Ranks',      182,  56, rpMeccan);
  S( 38, 'ص',          'Sad',              'The Letter Sad',                88,  38, rpMeccan);
  S( 39, 'الزمر',      'Az-Zumar',         'The Troops',                    75,  59, rpMeccan);
  S( 40, 'غافر',       'Ghafir',           'The Forgiver',                  85,  60, rpMeccan);
  S( 41, 'فصلت',       'Fussilat',         'Explained in Detail',           54,  61, rpMeccan);
  S( 42, 'الشورى',     'Ash-Shuraa',       'The Consultation',              53,  62, rpMeccan);
  S( 43, 'الزخرف',     'Az-Zukhruf',       'The Ornaments of Gold',         89,  63, rpMeccan);
  S( 44, 'الدخان',     'Ad-Dukhan',        'The Smoke',                     59,  64, rpMeccan);
  S( 45, 'الجاثية',    'Al-Jathiyah',      'The Crouching',                 37,  65, rpMeccan);
  S( 46, 'الأحقاف',    'Al-Ahqaf',         'The Wind-Curved Sandhills',     35,  66, rpMeccan);
  S( 47, 'محمد',       'Muhammad',         'Muhammad',                      38,  95, rpMedinan);
  S( 48, 'الفتح',      'Al-Fath',          'The Victory',                   29, 111, rpMedinan);
  S( 49, 'الحجرات',    'Al-Hujurat',       'The Rooms',                     18, 106, rpMedinan);
  S( 50, 'ق',          'Qaf',              'The Letter Qaf',                45,  34, rpMeccan);
  S( 51, 'الذاريات',   'Adh-Dhariyat',     'The Winnowing Winds',           60,  67, rpMeccan);
  S( 52, 'الطور',      'At-Tur',           'The Mount',                     49,  76, rpMeccan);
  S( 53, 'النجم',      'An-Najm',          'The Star',                      62,  23, rpMeccan);
  S( 54, 'القمر',      'Al-Qamar',         'The Moon',                      55,  37, rpMeccan);
  S( 55, 'الرحمن',     'Ar-Rahman',        'The Beneficent',                78,  97, rpMedinan);
  S( 56, 'الواقعة',    'Al-Waqi''ah',      'The Inevitable',                96,  46, rpMeccan);
  S( 57, 'الحديد',     'Al-Hadid',         'The Iron',                      29,  94, rpMedinan);
  S( 58, 'المجادلة',   'Al-Mujadila',      'The Pleading Woman',            22, 105, rpMedinan);
  S( 59, 'الحشر',      'Al-Hashr',         'The Exile',                     24, 101, rpMedinan);
  S( 60, 'الممتحنة',   'Al-Mumtahanah',    'She That Is Examined',          13,  91, rpMedinan);
  S( 61, 'الصف',       'As-Saf',           'The Ranks',                     14, 109, rpMedinan);
  S( 62, 'الجمعة',     'Al-Jumu''ah',      'The Congregation Friday',       11, 110, rpMedinan);
  S( 63, 'المنافقون',  'Al-Munafiqun',     'The Hypocrites',                11, 104, rpMedinan);
  S( 64, 'التغابن',    'At-Taghabun',      'The Mutual Disillusion',        18, 108, rpMedinan);
  S( 65, 'الطلاق',     'At-Talaq',         'The Divorce',                   12,  99, rpMedinan);
  S( 66, 'التحريم',    'At-Tahrim',        'The Prohibition',               12, 107, rpMedinan);
  S( 67, 'الملك',      'Al-Mulk',          'The Sovereignty',               30,  77, rpMeccan);
  S( 68, 'القلم',      'Al-Qalam',         'The Pen',                       52,   2, rpMeccan);
  S( 69, 'الحاقة',     'Al-Haqqah',        'The Reality',                   52,  78, rpMeccan);
  S( 70, 'المعارج',    'Al-Ma''arij',      'The Ascending Stairways',       44,  79, rpMeccan);
  S( 71, 'نوح',        'Nuh',              'Noah',                          28,  71, rpMeccan);
  S( 72, 'الجن',       'Al-Jinn',          'The Jinn',                      28,  40, rpMeccan);
  S( 73, 'المزمل',     'Al-Muzzammil',     'The Enshrouded One',            20,   3, rpMeccan);
  S( 74, 'المدثر',     'Al-Muddaththir',   'The Cloaked One',               56,   4, rpMeccan);
  S( 75, 'القيامة',    'Al-Qiyamah',       'The Resurrection',              40,  31, rpMeccan);
  S( 76, 'الانسان',    'Al-Insan',         'The Man',                       31,  98, rpMedinan);
  S( 77, 'المرسلات',   'Al-Mursalat',      'The Emissaries',                50,  33, rpMeccan);
  S( 78, 'النبإ',      'An-Naba',          'The Tidings',                   40,  80, rpMeccan);
  S( 79, 'النازعات',   'An-Nazi''at',      'Those Who Drag Forth',          46,  81, rpMeccan);
  S( 80, 'عبس',        'Abasa',            'He Frowned',                    42,  24, rpMeccan);
  S( 81, 'التكوير',    'At-Takwir',        'The Overthrowing',              29,   7, rpMeccan);
  S( 82, 'الإنفطار',   'Al-Infitar',       'The Cleaving',                  19,  82, rpMeccan);
  S( 83, 'المطففين',   'Al-Mutaffifin',    'The Defrauding',                36,  86, rpMeccan);
  S( 84, 'الإنشقاق',   'Al-Inshiqaq',      'The Sundering',                 25,  83, rpMeccan);
  S( 85, 'البروج',     'Al-Buruj',         'The Mansions of the Stars',     22,  27, rpMeccan);
  S( 86, 'الطارق',     'At-Tariq',         'The Nightcommer',               17,  36, rpMeccan);
  S( 87, 'الأعلى',     'Al-A''la',         'The Most High',                 19,   8, rpMeccan);
  S( 88, 'الغاشية',    'Al-Ghashiyah',     'The Overwhelming',              26,  68, rpMeccan);
  S( 89, 'الفجر',      'Al-Fajr',          'The Dawn',                      30,  10, rpMeccan);
  S( 90, 'البلد',      'Al-Balad',         'The City',                      20,  35, rpMeccan);
  S( 91, 'الشمس',      'Ash-Shams',        'The Sun',                       15,  26, rpMeccan);
  S( 92, 'الليل',      'Al-Layl',          'The Night',                     21,   9, rpMeccan);
  S( 93, 'الضحى',      'Ad-Duhaa',         'The Morning Hours',             11,  11, rpMeccan);
  S( 94, 'الشرح',      'Ash-Sharh',        'The Relief',                     8,  12, rpMeccan);
  S( 95, 'التين',      'At-Tin',           'The Fig',                        8,  28, rpMeccan);
  S( 96, 'العلق',      'Al-''Alaq',        'The Clot',                      19,   1, rpMeccan);
  S( 97, 'القدر',      'Al-Qadr',          'The Power',                      5,  25, rpMeccan);
  S( 98, 'البينة',     'Al-Bayyinah',      'The Clear Proof',                8, 100, rpMedinan);
  S( 99, 'الزلزلة',    'Az-Zalzalah',      'The Earthquake',                 8,  93, rpMedinan);
  S(100, 'العاديات',   'Al-''Adiyat',      'The Courser',                   11,  14, rpMeccan);
  S(101, 'القارعة',    'Al-Qari''ah',      'The Calamity',                  11,  30, rpMeccan);
  S(102, 'التكاثر',    'At-Takathur',      'The Rivalry in World Increase',  8,  16, rpMeccan);
  S(103, 'العصر',      'Al-''Asr',         'The Declining Day',              3,  13, rpMeccan);
  S(104, 'الهمزة',     'Al-Humazah',       'The Traducer',                   9,  32, rpMeccan);
  S(105, 'الفيل',      'Al-Fil',           'The Elephant',                   5,  19, rpMeccan);
  S(106, 'قريش',       'Quraysh',          'Quraysh',                        4,  29, rpMeccan);
  S(107, 'الماعون',    'Al-Ma''un',        'The Small Kindnesses',           7,  17, rpMeccan);
  S(108, 'الكوثر',     'Al-Kawthar',       'The Abundance',                  3,  15, rpMeccan);
  S(109, 'الكافرون',   'Al-Kafirun',       'The Disbelievers',               6,  18, rpMeccan);
  S(110, 'النصر',      'An-Nasr',          'The Divine Support',             3, 114, rpMedinan);
  S(111, 'المسد',      'Al-Masad',         'The Palm Fiber',                 5,   6, rpMeccan);
  S(112, 'الإخلاص',    'Al-Ikhlas',        'The Sincerity',                  4,  22, rpMeccan);
  S(113, 'الفلق',      'Al-Falaq',         'The Daybreak',                   5,  20, rpMeccan);
  S(114, 'الناس',      'An-Nas',           'Mankind',                        6,  21, rpMeccan);
end;

initialization
  InitSurahData;

end.
