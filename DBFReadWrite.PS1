# encountered problems: returning arrays of objects if one statement writes something to the console ==> return just one value!
#                       everything looks right but FileStream.Read returns always the default values of the buffer ==> set the datatype to bytearray! [System.Byte[]]
#                       codepages ==> use System.Text.Encoding with the right codepage, i.e. 850 or 437
#                       empty date fields ==> [System.DateTime]::Minvalue
#                       converting hashset to object ==> $o = new-object PSObject -Property $h.Fields

# returns the type of the dbf-file (dBaseIII, dBaseIV, FoxPro) and memofile-info (DBT, FPT)
function Test-DBF {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory=$true,
                   ValueFromPipeline=$true,
                   HelpMessage="Provide DBF-filename")]
        [string]$DBFFilename )
    $DBFFileHandle = [System.IO.File]::Open($DBFFilename,
                                            [System.IO.FileMode]::Open,
                                            [System.IO.FileAccess]::Read,
                                            [System.IO.FileShare]::ReadWrite)
    $DBFType = $DBFFileHandle.ReadByte()
    $DBFObject = _NewDBFObject -DbfType $DBFType
    $DBFFileHandle.Close()
    
    # determining memofield blocksize when FPT-memos
    if ($DBFObject.hasMemoFile -and $DBFObject.memoExt -eq "FPT")
    {
        $DBFFileHandle = [System.IO.File]::Open([System.IO.Path]::ChangeExtension($DBFFilename, $DBFObject.memoExt),
                                            [System.IO.FileMode]::Open,
                                            [System.IO.FileAccess]::Read,
                                            [System.IO.FileShare]::ReadWrite)
        [System.Byte[]] $Buffer = @(0x00) * 2
        $Position = $DBFFileHandle.Seek(6, [System.IO.SeekOrigin]::Begin)
        $BytesRead = $DBFFileHandle.Read($Buffer, 0, 2)
        $DBFObject.memoBlockSize = $Buffer[1]+$Buffer[0]*256
        $DBFFileHandle.Close()
    }
    
    return $DBFObject
}

# returns header data and field definitions of the specified dbf-file
function Get-DBFStructure () {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory=$true,
                   ValueFromPipeline=$true,
                   HelpMessage="Provide DBF-filename")]
        [string]$DBFFilename
         )

    $DBFFileHandle = [System.IO.File]::Open($DBFFilename,
                                        [System.IO.FileMode]::Open,
                                        [System.IO.FileAccess]::Read,
                                        [System.IO.FileShare]::ReadWrite)

    $DBFField = New-Object PSObject
    $DBFStructure = New-Object PSObject
    $DBFStructure | Add-Member -Type NoteProperty -Name LastUpdate -Value 0
    $DBFStructure | Add-Member -Type NoteProperty -Name DataOffset -Value 0
    $DBFStructure | Add-Member -Type NoteProperty -Name RecordSize -Value 0
    $DBFStructure | Add-Member -Type NoteProperty -Name NumRecords -Value 0
    $DBFStructure | Add-Member -Type NoteProperty -Name NumFields -Value 0
    #$DBFStructure | Add-Member -Type NoteProperty -Name Fields -Value []$DBFFields
    $DBFStructure | Add-Member -Type NoteProperty -Name Fields -Value @()
    $DBFStructure | Add-Member -Type NoteProperty -Name Encoding -Value 0
    $DBFStructure | Add-Member -Type NoteProperty -Name LanguageDriver -Value 0

    # PropertySet: http://mow001.blogspot.de/2006/01/some-fun-with-monads-add-member-mp3.html
    # to ask for propertySet use select from the returned object: $x | select HeaderInfo
    $DBFStructure | Add-Member -Type PropertySet -Name HeaderInfo -Value ([string[]]("LastUpdate", "DataOffset", "RecordSize", "NumRecords", "NumFields"))

    [System.Byte[]] $NumTemp = @(0x00) * 4

    # reading number of records
    $Position = $DBFFileHandle.Seek(4, [System.IO.SeekOrigin]::Begin)
    $BytesRead = $DBFFileHandle.Read($NumTemp, 0, 4)
    $DBFStructure.NumRecords = Bin2Int32 ($NumTemp)
    
    $NumTemp = @(0x00) * 4
    
    # reading length of header
    $Position = $DBFFileHandle.Seek(8, [System.IO.SeekOrigin]::Begin)
    $BytesRead = $DBFFileHandle.Read($NumTemp, 0, 2)
    $DBFStructure.DataOffset = Bin2Int32 ($NumTemp)

    $NumTemp = @(0x00) * 4

    # reading length of record, including deleted byte
    $Position = $DBFFileHandle.Seek(10, [System.IO.SeekOrigin]::Begin)
    $BytesRead = $DBFFileHandle.Read($NumTemp, 0, 2)
    $DBFStructure.RecordSize = Bin2Int32 ($NumTemp)

    $NumTemp = @(0x00) * 4

    # reading date of last update
    $Position = $DBFFileHandle.Seek(1, [System.IO.SeekOrigin]::Begin)
    $BytesRead = $DBFFileHandle.Read($NumTemp, 0, 3)
    $Year=$NumTemp[0]+1900
    $Month=$NumTemp[1]
    $Day=$NumTemp[2]
    if ($Month -eq 0 -or $Day -eq 0) {
        $DBFStructure.LastUpdate = [DateTime]::MinValue
    } else {
        $DBFStructure.LastUpdate = New-Object System.DateTime($Year,$Month,$Day)
    }

    $NumTemp = @(0x00) * 4

    # reading language driver byte also known as encoding
    $Position = $DBFFileHandle.Seek(29, [System.IO.SeekOrigin]::Begin)
    $BytesRead = $DBFFileHandle.Read($NumTemp, 0, 1)
    $DBFStructure.LanguageDriver = [int]$NumTemp[0]
    $DBFStructure.Encoding = [int](ConvertLanguageDriver2CodePage -LanguageDriver $DBFStructure.LanguageDriver)
    
    # Field descriptors end with 0x0D. Header lengths may include padding.
    [void]$DBFFileHandle.Seek(32, [System.IO.SeekOrigin]::Begin)
	$FieldPos = 0
    while ($DBFFileHandle.Position -lt $DBFStructure.DataOffset) {
        $FirstByte = $DBFFileHandle.ReadByte()
        if ($FirstByte -eq 0x0D) { break }
        if ($FirstByte -lt 0 -or $DBFFileHandle.Position + 31 -gt $DBFStructure.DataOffset) {
            throw "Invalid DBF field descriptor terminator."
		}
        [byte[]]$NumTemp = New-Object byte[] 32
        $NumTemp[0] = [byte]$FirstByte
        if ($DBFFileHandle.Read($NumTemp, 1, 31) -ne 31) { throw "Truncated DBF field descriptor." }
        $ZeroIndex = [Array]::IndexOf($NumTemp, [byte]0, 0, 11)
        if ($ZeroIndex -lt 0) { $ZeroIndex = 11 }
        $Name = [Text.Encoding]::ASCII.GetString($NumTemp, 0, $ZeroIndex)
        if ([string]::IsNullOrEmpty($Name)) { throw "DBF field with empty name." }
        $Type = [char]$NumTemp[11]
        $Length = [int]$NumTemp[16]
        $Decimals = [int]$NumTemp[17]
        # Clipper long-character fields encode their length across bytes 16/17.
        if ($Type -eq 'C') {
            $Length += 256 * $Decimals
            $Decimals = 0
		}
        if ($Length -lt 1) { throw "Invalid field length in '$Name'." }
        $DBFStructure.Fields += [pscustomobject]@{
            Nr = $DBFStructure.Fields.Count + 1; Name = $Name; Type = [string]$Type
            FieldPos = $FieldPos; Length = $Length; Decimal = $Decimals
        }
        $FieldPos += $Length
    }
    if ($FirstByte -ne 0x0D) { throw "Missing DBF field descriptor terminator." }
    $DBFStructure.NumFields = $DBFStructure.Fields.Count
    if ($FieldPos + 1 -ne $DBFStructure.RecordSize) {
        throw "DBF layout inconsistent: fields use $FieldPos bytes, record size is $($DBFStructure.RecordSize)."
    }
    
    $DBFFileHandle.Close()
    
    $DBFStructure
    
}

function ConvertLanguageDriver2CodePage {
    param([int]$LanguageDriver)
    # Common dBASE/FoxPro language driver markers; 0/unknown is ambiguous
    # (especially for Harbour) and MUST be overridden with -CodePage.
	switch ($LanguageDriver) {
        0x01 { return 437 }
        0x02 { return 850 }
        0x03 { return 1252 }
        0x57 { return 1252 }
        0x64 { return 852 }
        0x65 { return 866 }
        0x66 { return 865 }
        0x67 { return 861 }
        0x6A { return 737 }
        0x6B { return 857 }
        0xC8 { return 1250 }
        0xC9 { return 1251 }
        0xCA { return 1254 }
        0xCB { return 1253 }
        default { return 0 }
    }
}

# Explicit -CodePage always wins; we never silently assume CP850.
function _ResolveDBFEncoding([int]$CodePage, [int]$LanguageDriver) {
    if ($CodePage -eq 0) { $CodePage = ConvertLanguageDriver2CodePage $LanguageDriver }
    if ($CodePage -eq 0) {
        throw ('Unknown DBF codepage (language driver 0x{0:X2}). Supply -CodePage, e.g. 850 or 1252.' -f $LanguageDriver)
    }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Add-Type -AssemblyName System.Text.Encoding.CodePages
        [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
    }
    return [Text.Encoding]::GetEncoding($CodePage,
        [Text.EncoderFallback]::ExceptionFallback,
        [Text.DecoderFallback]::ExceptionFallback)
}

function _ReadExactly([IO.Stream]$Stream, [int]$Count) {
    [byte[]]$Data = New-Object byte[] $Count
    $Offset = 0
    while ($Offset -lt $Count) {
        $N = $Stream.Read($Data, $Offset, $Count - $Offset)
        if ($N -le 0) { throw 'Unexpected end of DBF/FPT file.' }
        $Offset += $N
    }
    return ,$Data
}

function _UInt32BE([byte[]]$Bytes, [int]$Offset = 0) {
    return [uint32](([uint64]$Bytes[$Offset] -shl 24) -bor
        ([uint64]$Bytes[$Offset+1] -shl 16) -bor
        ([uint64]$Bytes[$Offset+2] -shl 8) -bor [uint64]$Bytes[$Offset+3])
}
function _UInt32LE([byte[]]$Bytes, [int]$Offset = 0) {
    return [uint32](([uint64]$Bytes[$Offset+3] -shl 24) -bor
        ([uint64]$Bytes[$Offset+2] -shl 16) -bor
        ([uint64]$Bytes[$Offset+1] -shl 8) -bor [uint64]$Bytes[$Offset])
}
function _UInt32BytesBE([uint32]$Value) {
    [byte[]]$Bytes = [BitConverter]::GetBytes($Value)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($Bytes) }
    return ,$Bytes
}
function _UInt32BytesLE([uint32]$Value) {
    [byte[]]$Bytes = [BitConverter]::GetBytes($Value)
    if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($Bytes) }
    return ,$Bytes
}

function _HasPendingDBFChanges($DBFInfo) {
    if ($DBFInfo.LoadedRecNo -le 0) { return $false }
    foreach ($F in $DBFInfo.Header.Fields) {
        $Name = $F.Name
        if (-not [object]::Equals($DBFInfo.Fields[$Name], $DBFInfo.OriginalValues[$Name])) {
            return $true
        }
    }
    return $false
}

# Preflight: serialize an edited field before writing ANY record bytes.
function _SerializeDBFField($DBFInfo, $Field, $Value) {
    $Len = [int]$Field.Length
    [byte[]]$Bytes = New-Object byte[] $Len
    for ($I = 0; $I -lt $Len; $I++) { $Bytes[$I] = 0x20 }
    $Culture = [Globalization.CultureInfo]::InvariantCulture
    switch ($Field.Type) {
        'C' {
            $Encoded = $DBFInfo.TextEncoding.GetBytes([string]$Value)
            if ($Encoded.Length -gt $Len) { throw "Text too long for '$($Field.Name)' ($($Encoded.Length) > $Len bytes)." }
            [Array]::Copy($Encoded, 0, $Bytes, 0, $Encoded.Length)
        }
        'N' {
            if ($null -ne $Value -and [string]$Value -ne '') {
                if ($Value -is [string]) { $Num = [decimal]::Parse($Value, [Globalization.NumberStyles]::Float, $Culture) }
                else { $Num = [Convert]::ToDecimal($Value, $Culture) }
                if ([decimal]::Round($Num, [int]$Field.Decimal) -ne $Num) { throw "Too many decimals for '$($Field.Name)'." }
                $Number = $Num.ToString(('F{0}' -f [int]$Field.Decimal), $Culture)
                if ($Number.Length -gt $Len) { throw "Number too long for '$($Field.Name)'." }
                $Src = [Text.Encoding]::ASCII.GetBytes($Number)
                [Array]::Copy($Src, 0, $Bytes, $Len - $Src.Length, $Src.Length)
            }
        }
        'F' {
            # FoxPro floating ASCII fields, with the same fixed-width constraints.
            if ($null -ne $Value -and [string]$Value -ne '') {
                if ($Value -is [string]) { $Num = [decimal]::Parse($Value, [Globalization.NumberStyles]::Float, $Culture) }
                else { $Num = [Convert]::ToDecimal($Value, $Culture) }
                if ([decimal]::Round($Num, [int]$Field.Decimal) -ne $Num) { throw "Too many decimals for '$($Field.Name)'." }
                $Number = $Num.ToString(('F{0}' -f [int]$Field.Decimal), $Culture)
                if ($Number.Length -gt $Len) { throw "Float too long for '$($Field.Name)'." }
                $Src = [Text.Encoding]::ASCII.GetBytes($Number)
                [Array]::Copy($Src, 0, $Bytes, $Len - $Src.Length, $Src.Length)
            }
        }
        'D' {
            if ($Len -ne 8) { throw "Unsupported date width in '$($Field.Name)'." }
            if ($null -ne $Value -and [datetime]$Value -ne [datetime]::MinValue) {
                $Src = [Text.Encoding]::ASCII.GetBytes(([datetime]$Value).ToString('yyyyMMdd', $Culture))
                [Array]::Copy($Src, 0, $Bytes, 0, 8)
            }
        }
        'L' {
            if ($Len -ne 1) { throw "Unsupported logical width in '$($Field.Name)'." }
            if ($null -ne $Value -and $Value -isnot [bool]) { throw "Logical '$($Field.Name)' requires true, false or null." }
            if ($null -eq $Value) { $Bytes[0] = [byte][char]'?' }
            elseif ([bool]$Value) { $Bytes[0] = [byte][char]'T' }
            else { $Bytes[0] = [byte][char]'F' }
        }
        default { throw "Write not supported for DBF field '$($Field.Name)' (type $($Field.Type))." }
    }
    return ,$Bytes
}

# FPT append-only: never overwrite or reuse existing memo blocks (safe for shared old references).
function _AppendFPTMemo($DBFInfo, [byte[]]$Payload) {
    $FPT = $DBFInfo.FilehandleOfMemo
    if ($null -eq $FPT -or -not $FPT.CanWrite) { throw 'FPT is not writable.' }
    $BlockSize = [int]$DBFInfo.Type.memoBlockSize
    if ($BlockSize -lt 8) { throw 'Invalid FPT block size.' }
    [void]$FPT.Seek(0, [IO.SeekOrigin]::Begin)
    $Header = _ReadExactly $FPT 8
    $HeaderNext = [uint64](_UInt32BE $Header 0)
    $FileNext = [uint64][Math]::Ceiling([double]$FPT.Length / $BlockSize)
    $Next = [Math]::Max([Math]::Max($HeaderNext, $FileNext), [uint64][Math]::Ceiling(512.0/$BlockSize))
    $Blocks = [uint64][Math]::Ceiling(([double]$Payload.Length + 8) / $BlockSize)
    if ($Next + $Blocks -gt [uint32]::MaxValue) { throw 'FPT block address overflow.' }
    $Address = [long]$Next * $BlockSize
    [void]$FPT.Seek($Address, [IO.SeekOrigin]::Begin)
    [byte[]]$TypeBytes = _UInt32BytesBE 1
    [byte[]]$LengthBytes = _UInt32BytesBE ([uint32]$Payload.Length)
    $FPT.Write($TypeBytes, 0, 4)
    $FPT.Write($LengthBytes, 0, 4)
    $FPT.Write($Payload, 0, $Payload.Length)
    $PaddedEnd = [long]($Next + $Blocks) * $BlockSize
    if ($FPT.Length -lt $PaddedEnd) { $FPT.SetLength($PaddedEnd) }
    $FPT.Flush()
    [void]$FPT.Seek(0, [IO.SeekOrigin]::Begin)
    [byte[]]$NewNext = _UInt32BytesBE ([uint32]($Next + $Blocks))
    $FPT.Write($NewNext, 0, 4)
    $FPT.Flush()
    return [uint32]$Next
}

function _MemoPointerBytes($Field, [uint32]$Pointer) {
    if ($Field.Length -eq 4) { return ,(_UInt32BytesLE $Pointer) }
    if ($Field.Length -eq 10) {
        if ($Pointer -eq 0) { return ,([Text.Encoding]::ASCII.GetBytes('          ')) }
        return ,([Text.Encoding]::ASCII.GetBytes($Pointer.ToString().PadLeft(10, ' ')))
    }
    throw "Unsupported FPT memo pointer width $($Field.Length) in '$($Field.Name)'."
}

function _WriteDBFHeaderDate($DBFInfo) {
    $Today = Get-Date
    [byte[]]$DateBytes = @([byte]($Today.Year - 1900), [byte]$Today.Month, [byte]$Today.Day)
    [void]$DBFInfo.FilehandleOfDBF.Seek(1, [IO.SeekOrigin]::Begin)
    $DBFInfo.FilehandleOfDBF.Write($DateBytes, 0, 3)
    $DBFInfo.Header.LastUpdate = $Today.Date
}

function _SaveRecord($DBFInfo) {
    if ($DBFInfo.ReadOnly -or -not $DBFInfo.FilehandleOfDBF.CanWrite) { throw 'DBF opened read-only.' }
    if ($DBFInfo.LoadedRecNo -le 0 -or $DBFInfo.LoadedRecNo -ne $DBFInfo.RecNo) { throw 'No current loaded record.' }
    $Changed = @()
    $Serialized = @{}
    foreach ($Field in $DBFInfo.Header.Fields) {
        $Name = $Field.Name
        if (-not [object]::Equals($DBFInfo.Fields[$Name], $DBFInfo.OriginalValues[$Name])) {
            $Changed += $Field
            if ($Field.Type -eq 'M') {
                if ($DBFInfo.Type.memoExt -ne 'FPT') { throw 'Only FPT memo writes are supported.' }
                if ($Field.Length -notin @(4,10)) { throw "Unsupported memo pointer width in '$Name'." }
                if ($null -ne $DBFInfo.Fields[$Name] -and $DBFInfo.Fields[$Name] -isnot [string]) { throw "Memo '$Name' must be text." }
                $Serialized[$Name] = $DBFInfo.TextEncoding.GetBytes([string]$DBFInfo.Fields[$Name])
            } else {
                $Serialized[$Name] = _SerializeDBFField $DBFInfo $Field $DBFInfo.Fields[$Name]
            }
        }
    }
    if ($Changed.Count -eq 0) { return }
    $Position = [long]$DBFInfo.Header.DataOffset + ([long]$DBFInfo.RecNo - 1) * $DBFInfo.Header.RecordSize
    $DBF = $DBFInfo.FilehandleOfDBF
    [void]$DBF.Seek($Position, [IO.SeekOrigin]::Begin)
    $Current = _ReadExactly $DBF $DBFInfo.Header.RecordSize
    for ($I = 0; $I -lt $Current.Length; $I++) {
        if ($Current[$I] -ne $DBFInfo.OriginalRecord[$I]) {
            throw 'Current record was changed on disk; reload before writing.'
        }
    }
    [byte[]]$NewRecord = [byte[]]$Current.Clone()
    foreach ($Field in $Changed) {
        $Name = $Field.Name
        if ($Field.Type -eq 'M') {
            $Pointer = [uint32]0
            if ($Serialized[$Name].Length -gt 0) { $Pointer = _AppendFPTMemo $DBFInfo $Serialized[$Name] }
            $NewBytes = _MemoPointerBytes $Field $Pointer
        } else { $NewBytes = [byte[]]$Serialized[$Name] }
        [Array]::Copy($NewBytes, 0, $NewRecord, 1 + [int]$Field.FieldPos, [int]$Field.Length)
    }
    [void]$DBF.Seek($Position, [IO.SeekOrigin]::Begin)
    $DBF.Write($NewRecord, 0, $NewRecord.Length)
    _WriteDBFHeaderDate $DBFInfo
    $DBF.Flush()
    $DBFInfo.OriginalRecord = $NewRecord
    foreach ($Field in $DBFInfo.Header.Fields) { $DBFInfo.OriginalValues[$Field.Name] = $DBFInfo.Fields[$Field.Name] }
}

# returns integer from byte array
function Bin2Int16BE ()    
{
  [CmdletBinding()]
  #TODO: set OutputType to UINT16
  param([System.Byte[]] $Bytes)
  return $Bytes[1]+$Bytes[0]*256  #attention BIG ENDIAN
}

# returns integer from byte array
function Bin2Int32 ()    
{
  [CmdletBinding()]
  #TODO: set OutputType to UINT32
  param([System.Byte[]] $Bytes)
  return $Bytes[0]+$Bytes[1]*256+$Bytes[2]*256*256+$Bytes[3]*256*256*256
}

# returns byte array from integer
function Int322Bin ()
{
    [CmdletBinding()]
    Param([UInt32]$Value)
    [System.Byte[]]$NumTemp=@(0x00)*4
    $NumTemp[3] = [Math]::Floor($Value/(256*256*256))
    $Rest = $Value % (256*256*256)
    $NumTemp[2] = [Math]::Floor($Rest/(256*256))
    $Rest = $Value % (256*256)
    $NumTemp[1] = [Math]::Floor($Rest/(256))
    $Rest = $Value % 256
    $NumTemp[0] = $Rest
    return $NumTemp
}

# returns byte array from integer
function Int322BinBE ()
{
    [CmdletBinding()]
    Param([UInt32]$Value)
    [System.Byte[]]$NumTemp=@(0x00)*4
    $NumTemp[0] = [Math]::Floor($Value/(256*256*256))
    $Rest = $Value % (256*256*256)
    $NumTemp[1] = [Math]::Floor($Rest/(256*256))
    $Rest = $Value % (256*256)
    $NumTemp[2] = [Math]::Floor($Rest/(256))
    $Rest = $Value % 256
    $NumTemp[3] = $Rest
    return $NumTemp
}

# Open DBF for reading or (exclusive) update. No implicit CP850 fallback.
function Use-DBF () {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory=$true,
                   ValueFromPipeline=$true,
                   HelpMessage="Provide DBF-filename")]
        [string]$DBFFilename,
        [Parameter(Mandatory=$false,
                   HelpMessage="Open DBF in ReadWrite-mode")]
        [Switch]$ReadWrite=$false,
		[int]$CodePage = 0
	)

    $DBFInfo = New-Object PSObject
    _AddPropertiesAndMethods $DBFInfo

	$DBFInfo.ReadOnly = -not [bool]$ReadWrite
    $DBFInfo.Type = Test-DBF $DBFFilename
	if ($DBFInfo.Type.Type -eq 'unknown') { throw ('Unsupported DBF signature 0x{0:X2}' -f $DBFInfo.Type.ID) }
    $DBFInfo.Header = Get-DBFStructure $DBFFilename
    
    $DBFInfo.TextEncoding = _ResolveDBFEncoding $CodePage $DBFInfo.Header.LanguageDriver
    $DBFInfo.Header.Encoding = $DBFInfo.TextEncoding.CodePage
    foreach ($Field in $DBFInfo.Header.Fields) { $DBFInfo.Fields[$Field.Name] = $null }
    $Access = [IO.FileAccess]::Read
    $Share = [IO.FileShare]::ReadWrite
    if ($ReadWrite) {
        $Access = [IO.FileAccess]::ReadWrite
        $Share = [IO.FileShare]::None  # no silent lost updates / concurrent memo allocation
	}

    try {
        $DBFInfo.FilehandleOfDBF = [IO.File]::Open($DBFFilename, [IO.FileMode]::Open, $Access, $Share)
        if ($DBFInfo.Type.hasMemoFile) {
            $MemoFile = [IO.Path]::ChangeExtension($DBFFilename, $DBFInfo.Type.memoExt)
            $DBFInfo.FilehandleOfMemo = [IO.File]::Open($MemoFile, [IO.FileMode]::Open, $Access, $Share)
        }
    } catch {
        if ($null -ne $DBFInfo.FilehandleOfDBF) { $DBFInfo.FilehandleOfDBF.Dispose() }
        if ($null -ne $DBFInfo.FilehandleOfMemo) { $DBFInfo.FilehandleOfMemo.Dispose() }
        throw
	}

    return $DBFInfo
}

# adds Properties and Methods to DBFInfo-Object
Function _AddPropertiesAndMethods {
    Param(
        $DBFInfo
    )

    $DBFInfo | Add-Member -Type NoteProperty -Name Header -Value $null
    $DBFInfo | Add-Member -Type NoteProperty -Name Type -Value $null
    $DBFInfo | Add-Member -Type NoteProperty -Name ReadOnly -Value $true
    $DBFInfo | Add-Member -Type NoteProperty -Name TextEncoding -Value $null
    $DBFInfo | Add-Member -Type NoteProperty -Name OriginalRecord -Value $null
    $DBFInfo | Add-Member -Type NoteProperty -Name OriginalValues -Value @{}
    $DBFInfo | Add-Member -Type NoteProperty -Name LoadedRecNo -Value 0
    $DBFInfo | Add-Member -Type NoteProperty -Name RecNo -Value 0
    $DBFInfo | Add-Member -Type NoteProperty -Name BOF -Value $true
    $DBFInfo | Add-Member -Type NoteProperty -Name EOF -Value $true
    $DBFInfo | Add-Member -Type NoteProperty -Name Deleted -Value $false
    $DBFInfo | Add-Member -Type NoteProperty -Name Fields -Value @{}
    $DBFInfo | Add-Member -Type NoteProperty -Name FilehandleOfDBF -Value $null
    $DBFInfo | Add-Member -Type NoteProperty -Name FilehandleOfMemo -Value $null
    $DBFInfo | Add-Member -Type ScriptMethod -Name GoTo -Value { param($recNo) _GoTo $this $recNo }
    $DBFInfo | Add-Member -Type ScriptMethod -Name GoTop -Value { _GoTop $this }
    $DBFInfo | Add-Member -Type ScriptMethod -Name GoBottom -Value { _GoBottom $this }
    $DBFInfo | Add-Member -Type ScriptMethod -Name Close -Value { _CloseDBF $this }
    $DBFInfo | Add-Member -Type ScriptMethod -Name Skip -Value { param($records) _Skip $this $records }
    $DBFInfo | Add-Member -Type ScriptMethod -Name ListAll -Value { _ListAll $this }
    $DBFInfo | Add-Member -Type ScriptMethod -Name ReadRecord -Value { param([Parameter(ValueFromPipeline=$true)]$recNo) _ReadRecord $this $recNo }
    $DBFInfo | Add-Member -Type ScriptMethod -Name GetMemofieldInternals -Value { param($fieldname) _MemofieldInternals $this $fieldname }
    $DBFInfo | Add-Member -Type ScriptMethod -Name AppendBlank -Value { _AppendBlank $this }
    $DBFInfo | Add-Member -Type ScriptMethod -Name SaveRecord -Value { _SaveRecord $this }
    # Raw pointer repair; does not need to read or decode the affected memo.
    # $db.ResetMemoPointer('NOTIZ', 42) works even if GoTo(42) fails.
    $DBFInfo | Add-Member -Type ScriptMethod -Name ResetMemoPointer -Value {
        param([string]$FieldName, $RecNo = $null)
        _Reset-MemofieldPointer $this $FieldName $RecNo
    }
    # Check a record's FPT references without trying to decode all DBF fields.
    $DBFInfo | Add-Member -Type ScriptMethod -Name CheckMemoPointers -Value {
        param([long]$RecNo)
        if (_HasPendingDBFChanges $this) { throw 'Save or discard pending changes before scanning memo pointers.' }
        if ($RecNo -lt 1 -or $RecNo -gt [long]$this.Header.NumRecords) { throw "Invalid DBF record number: $RecNo" }
        $Previous = $this.RecNo
        try {
            $this.RecNo = $RecNo
            _Check-MemofieldIntegrity $this
        } finally { $this.RecNo = $Previous }
    }
    $DBFInfo | Add-Member -Type ScriptMethod -Name DiscardChanges -Value {
        foreach ($Field in $this.Header.Fields) { $this.Fields[$Field.Name] = $this.OriginalValues[$Field.Name] }
    }

}

# creates an object about the type of DBF-file and if it has a memofile
Function _NewDBFObject {
    Param(
        [int]$DBFType  
    )

    $DBFObject = New-Object PSObject
    $DBFObject | Add-Member -Type NoteProperty -Name ID -Value 0
    $DBFObject | Add-Member -Type NoteProperty -Name Type -Value ""
    $DBFObject | Add-Member -Type NoteProperty -Name hasMemoFile -Value $false
    $DBFObject | Add-Member -Type NoteProperty -Name memoExt -Value "DBT"
    $DBFObject | Add-Member -Type NoteProperty -Name memoBlockSize -Value 512     # DBT Blocksize is always 512Bytes
    $DBFObject.ID = $DBFType
    switch ($DBFType)
    {
        3 {$DBFObject.Type = "DBF-file"}
        48 {$DBFObject.Type = "Visual FoxPro+FPT"; $DBFObject.hasMemoFile = $true; $DBFObject.memoExt = "FPT"}
        49 {$DBFObject.Type = "Visual FoxPro+FPT"; $DBFObject.hasMemoFile = $true; $DBFObject.memoExt = "FPT"}
        50 {$DBFObject.Type = "Visual FoxPro+FPT"; $DBFObject.hasMemoFile = $true; $DBFObject.memoExt = "FPT"}
        131 {$DBFObject.Type = "DBF+DBT-files"; $DBFObject.hasMemoFile = $true}
        139 {$DBFObject.Type = "DBF(dBase IV)+DBT-files"; $DBFObject.hasMemoFile = $true}
        245 {$DBFObject.Type = "DBF+FPT-files"; $DBFObject.hasMemoFile = $true; $DBFObject.memoExt = "FPT"}
        default {$DBFObject.Type = "unknown"}
    }

    $DBFObject
}

function New-Field {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,

        [Parameter(Mandatory=$true)]
        [ValidateSet(
            'C','N','F','D','L','M',
            'Character','Numeric','Float',
            'Date','Logical','Memo'
        )]
        [string]$Type,

        [int]$Length = 0,
        [int]$Decimal = 0
    )

    if ($Name -cnotmatch '^[A-Za-z_][A-Za-z0-9_]{0,9}$') {
        throw "Invalid DBF field name: '$Name'. Maximum 10 ASCII characters."
    }

    $Aliases = @{
        Character = 'C'
        Numeric   = 'N'
        Float     = 'F'
        Date      = 'D'
        Logical   = 'L'
        Memo      = 'M'
    }

    $Code = $Type.ToUpperInvariant()
    if ($Aliases.ContainsKey($Type)) {
        $Code = $Aliases[$Type]
    }

    if (-not $PSBoundParameters.ContainsKey('Length')) {
        switch ($Code) {
            'C' { $Length = 10 }
            'N' { $Length = 10 }
            'F' { $Length = 12 }
            'D' { $Length = 8 }
            'L' { $Length = 1 }
            'M' { $Length = 10 }
        }
    }

    if ($Decimal -lt 0) {
        throw "Negative decimal count in field '$Name'."
    }

    switch ($Code) {
        'C' {
            if ($Length -lt 1 -or $Length -gt 65534 -or $Decimal -ne 0) {
                throw "Character field '$Name': length 1..65534, decimals 0."
            }
        }

        { $_ -in @('N','F') } {
            if ($Length -lt 1 -or $Length -gt 20 -or
                ($Decimal -gt 0 -and
                ($Decimal -gt 18 -or $Length -lt $Decimal + 2))) {
                throw "Numeric field '$Name': invalid length or decimals."
            }
        }

        'D' {
            if ($Length -ne 8 -or $Decimal -ne 0) {
                throw "Date field '$Name' must have length 8."
            }
        }

        'L' {
            if ($Length -ne 1 -or $Decimal -ne 0) {
                throw "Logical field '$Name' must have length 1."
            }
        }

        'M' {
            if ($Length -notin @(4,10) -or $Decimal -ne 0) {
                throw "FPT memo field '$Name' requires length 4 or 10."
            }
        }
    }

    return [PSCustomObject]@{
        PSTypeName = 'PSDBF.Field'
        Name       = $Name
        Type       = $Code
        Length     = $Length
        Decimal    = $Decimal
    }
}


function New-DBFLanguageDriver {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [int]$CodePage
    )

    switch ($CodePage) {
        437  { return 0x01 }
        850  { return 0x02 }
        1252 { return 0x03 }
        852  { return 0x64 }
        866  { return 0x65 }
        865  { return 0x66 }
        861  { return 0x67 }
        737  { return 0x6A }
        857  { return 0x6B }
        1250 { return 0xC8 }
        1251 { return 0xC9 }
        1254 { return 0xCA }
        1253 { return 0xCB }

        # UTF-8 und nicht eindeutig zugeordnete Codepages
        default { return 0x00 }
    }
}


function New-DBF {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$DBFFilename,

        [Parameter(Mandatory=$true)]
        [object[]]$Fields,

        [Parameter(Mandatory=$true)]
        [ValidateRange(1,65535)]
        [int]$CodePage,

        [ValidateSet('Harbour')]
        [string]$Format = 'Harbour',

        [ValidateSet('FPT')]
        [string]$MemoFormat = 'FPT',

        [ValidateRange(8,65535)]
        [int]$FPTBlockSize = 512
    )

    # Codepage validieren
    $Encoding = _ResolveDBFEncoding $CodePage 0

    if ($CodePage -ne 65001 -and -not $Encoding.IsSingleByte) {
        throw "Codepage $CodePage is not supported for fixed-width DBF fields."
    }

    # FPT-Blockgröße prüfen
    if ($FPTBlockSize -band ($FPTBlockSize - 1)) {
        throw 'FPTBlockSize must be a power of two.'
    }

    if ($null -eq $Fields -or
        $Fields.Count -lt 1 -or
        $Fields.Count -gt 255) {
        throw 'Supply between 1 and 255 field definitions.'
    }

    # Felddefinitionen normalisieren und prüfen
    $Normalized = @()
    $Names = @{}
    [long]$RecordLength = 1

    foreach ($Field in $Fields) {
        if ($null -eq $Field -or
            $null -eq $Field.PSObject.Properties['Name'] -or
            $null -eq $Field.PSObject.Properties['Type'] -or
            $null -eq $Field.PSObject.Properties['Length'] -or
            $null -eq $Field.PSObject.Properties['Decimal']) {
            throw 'Invalid field definition.'
        }

        $Spec = New-Field `
            -Name ([string]$Field.Name) `
            -Type ([string]$Field.Type) `
            -Length ([int]$Field.Length) `
            -Decimal ([int]$Field.Decimal)

        if ($Names.ContainsKey($Spec.Name)) {
            throw "Duplicate field name: '$($Spec.Name)'."
        }

        $Names[$Spec.Name] = $true
        $Normalized += $Spec
        $RecordLength += $Spec.Length
    }

    if ($RecordLength -gt 65535) {
        throw 'DBF record length exceeds 65535 bytes.'
    }

    $HasMemo = @(
        $Normalized | Where-Object { $_.Type -eq 'M' }
    ).Count -gt 0

    # DBF-Header: 32 Bytes Basisheader,
    # 32 Bytes je Feld, 1 Byte Terminator
    $HeaderLength = 32 + 32 * $Normalized.Count + 1

    $Today = (Get-Date).Date

    if ($Today.Year -lt 1900 -or $Today.Year -gt 2155) {
        throw 'Date outside classic DBF header range.'
    }

    $FullName = [IO.Path]::GetFullPath($DBFFilename)
    $FPTName = [IO.Path]::ChangeExtension($FullName, '.FPT')

    if ([IO.File]::Exists($FullName)) {
        throw "DBF already exists: $FullName"
    }

    if ($HasMemo -and [IO.File]::Exists($FPTName)) {
        throw "FPT already exists: $FPTName"
    }

    $DBFStream = $null
    $FPTStream = $null
    $CreatedDBF = $false
    $CreatedFPT = $false

    try {
        # DBF-Datei erstellen
        $DBFStream = [IO.File]::Open(
            $FullName,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $CreatedDBF = $true

        # 32-Byte-DBF-Header
        [byte[]]$Header = New-Object byte[] 32

        if ($HasMemo) {
            $Header[0] = 0xF5
        } else {
            $Header[0] = 0x03
        }

        $Header[1] = [byte]($Today.Year - 1900)
        $Header[2] = [byte]$Today.Month
        $Header[3] = [byte]$Today.Day

        # Datensatzanzahl bleibt zunächst 0

        [byte[]]$HL = [BitConverter]::GetBytes(
            [uint16]$HeaderLength
        )
        [byte[]]$RL = [BitConverter]::GetBytes(
            [uint16]$RecordLength
        )

        if (-not [BitConverter]::IsLittleEndian) {
            [Array]::Reverse($HL)
            [Array]::Reverse($RL)
        }

        [Array]::Copy($HL, 0, $Header, 8, 2)
        [Array]::Copy($RL, 0, $Header, 10, 2)

        $Header[29] = [byte](
            New-DBFLanguageDriver -CodePage $CodePage
        )

        $DBFStream.Write($Header, 0, $Header.Length)

        # Felddefinitionen schreiben
        [long]$Offset = 1

        foreach ($Field in $Normalized) {
            [byte[]]$Descriptor = New-Object byte[] 32

            [byte[]]$NameBytes =
                [Text.Encoding]::ASCII.GetBytes($Field.Name)

            [Array]::Copy(
                $NameBytes, 0,
                $Descriptor, 0,
                $NameBytes.Length
            )

            # Feldtyp
            $Descriptor[11] = [byte][char]$Field.Type

            # Feldposition
            [byte[]]$FieldOffset = _UInt32BytesLE (
                [uint32]$Offset
            )

            [Array]::Copy(
                $FieldOffset, 0,
                $Descriptor, 12, 4
            )

            # Länge / Dezimalstellen
            $Descriptor[16] = [byte]($Field.Length -band 255)

            if ($Field.Type -eq 'C') {
                $Descriptor[17] = [byte](
                    ($Field.Length -shr 8) -band 255
                )
            } else {
                $Descriptor[17] = [byte]$Field.Decimal
            }

            $DBFStream.Write(
                $Descriptor, 0, $Descriptor.Length
            )

            $Offset += $Field.Length
        }

        # Headerende und EOF
        $DBFStream.WriteByte(0x0D)
        $DBFStream.WriteByte(0x1A)

        $DBFStream.Flush()
        $DBFStream.Dispose()
        $DBFStream = $null

        # FPT erzeugen, falls Memofelder vorhanden
        if ($HasMemo) {
            $FPTStream = [IO.File]::Open(
                $FPTName,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
            $CreatedFPT = $true

            [byte[]]$FPTHeader = New-Object byte[] 512

            $FirstFreeBlock = [uint32][Math]::Ceiling(
                512.0 / $FPTBlockSize
            )

            # NextFreeBlock: Big Endian
            [byte[]]$NextBytes = _UInt32BytesBE $FirstFreeBlock

            [Array]::Copy(
                $NextBytes, 0,
                $FPTHeader, 0, 4
            )

            # Blockgröße: Big Endian
            $FPTHeader[6] = [byte](
                ($FPTBlockSize -shr 8) -band 255
            )
            $FPTHeader[7] = [byte](
                $FPTBlockSize -band 255
            )

            $FPTStream.Write(
                $FPTHeader, 0, $FPTHeader.Length
            )

            $FPTStream.Flush()
            $FPTStream.Dispose()
            $FPTStream = $null
        }

        # Fertige Datei über bestehende API öffnen
        return (Use-DBF -DBFFilename $FullName `
                        -ReadWrite -CodePage $CodePage)
    }
    catch {
        if ($null -ne $FPTStream) {
            $FPTStream.Dispose()
        }
        if ($null -ne $DBFStream) {
            $DBFStream.Dispose()
        }

        # Nur Dateien entfernen, die hier erstellt wurden
        if ($CreatedFPT) {
            Remove-Item -LiteralPath $FPTName -Force `
                -ErrorAction SilentlyContinue
        }
        if ($CreatedDBF) {
            Remove-Item -LiteralPath $FullName -Force `
                -ErrorAction SilentlyContinue
        }

        throw
    }
}


# Standalone ZAP
function Zap_DBF () {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory=$true,
                   ValueFromPipeline=$true,
                   HelpMessage="Provide DBF-filename")]
        [string]$DBFFilename
         )

    [System.Byte[]]$Numtemp=@() # important to set the type!

    $Type = Test-DBF $DBFFilename
    $Header = Get-DBFStructure $DBFFilename

    $DBFFileHandle = [System.IO.File]::Open($DBFFilename,
                                        [System.IO.FileMode]::Open,
                                        [System.IO.FileAccess]::Write,
                                        [System.IO.FileShare]::Write)

    $RecordPos = $Header.DataOffset
    $Position = $DBFFileHandle.Seek($RecordPos, [System.IO.SeekOrigin]::Begin)
    $DBFFileHandle.SetLength($Position)
    # to conform to dbase file handling:
    $DBFFileHandle.WriteByte(0x1A)

    # set RecordCount
    $NumTemp=@(0x00)*4
    $Position = $DBFFileHandle.Seek(4, [System.IO.SeekOrigin]::Begin)
    $BytesWritten = $DBFFileHandle.Write($NumTemp, 0, 4)

    # write modification date in header
    $NumTemp=@(0x00)*3
    $Date = Get-Date
    $NumTemp[0] = $Date.Year -1900
    $NumTemp[1] = $Date.Month
    $NumTemp[2] = $Date.Day
    $Position = $DBFFileHandle.Seek(1, [System.IO.SeekOrigin]::Begin)
    $BytesWritten = $DBFFileHandle.Write($NumTemp, 0, 3)

    $DBFFileHandle.Close()

    if ($Type.hasMemoFile)
    {
        switch($Type.memoExt) {
            "DBT"   {throw "not yet implemented! DBT"}
            "FPT"   {   $FPTFile = [System.IO.Path]::ChangeExtension($DBFFilename, $Type.MemoExt)
                        $FPTFileHandle = [System.IO.File]::Open($FptFile,
                                        [System.IO.FileMode]::Open,
                                        [System.IO.FileAccess]::ReadWrite,
                                        [System.IO.FileShare]::ReadWrite)
                        $NumTemp = @(0x00)*2
                        $Position = $FPTFileHandle.Seek(6, [System.IO.SeekOrigin]::Begin)
                        $BytesRead = $FPTFileHandle.Read($NumTemp, 0, 2)
                        $BlockSize = Bin2Int16BE $Numtemp

                        $HeaderSize = 512 
                        # Check if Flexfile3 is there!
                        $Flexfile3ID = "FlexFile3"
                        $NumTemp = @(0x00)*$Flexfile3ID.Length
                        $Position = $FPTFileHandle.Seek($HeaderSize, [System.IO.SeekOrigin]::Begin)
                        $BytesRead = $FPTFileHandle.Read($NumTemp, 0, $Flexfile3ID.Length)
                        If (([System.Text.Encoding]::ASCII.GetString($Numtemp)) -eq $Flexfile3ID) {
                            $HeaderSize = 1024
                        } 

                        $NextBlock = $HeaderSize / $BlockSize
                        # set next available Block
                        $Position = $FPTFileHandle.Seek(0, [System.IO.SeekOrigin]::Begin)
                        $Numtemp = Int322BinBE $NextBlock
                        $FPTFileHandle.Write($Numtemp, 0, 4)

                        $Position = $FPTFileHandle.Seek($HeaderSize, [System.IO.SeekOrigin]::Begin)
                        $FPTFileHandle.SetLength($Position)
                        $FPTFileHandle.Close()
            }
            default {throw "not yet implemented! $($Type.memoExt)"}
        }
    }
}

# should be internal functions

function _AppendBlank ($DBFInfo) {
    if ($DBFInfo.ReadOnly) { throw 'DBF opened read-only.' }
    if (_HasPendingDBFChanges $DBFInfo) { throw 'Unsaved field changes; call SaveRecord first.' }
    $DBF = $DBFInfo.FilehandleOfDBF
    $Size = [int]$DBFInfo.Header.RecordSize
    [byte[]]$Empty = New-Object byte[] $Size
    for ($I = 0; $I -lt $Size; $I++) { $Empty[$I] = 0x20 }
    foreach ($Field in $DBFInfo.Header.Fields) {
        if ($Field.Type -eq 'M' -and $DBFInfo.Type.memoExt -eq 'FPT') {
            $Ptr = _MemoPointerBytes $Field 0
            [Array]::Copy($Ptr, 0, $Empty, 1 + $Field.FieldPos, $Field.Length)
        }
	}
    $Offset = [long]$DBFInfo.Header.DataOffset + [long]$DBFInfo.Header.NumRecords * $Size
    if ($DBF.Length -lt $Offset) { throw 'DBF is truncated; cannot append.' }
    [void]$DBF.Seek($Offset, [IO.SeekOrigin]::Begin)
    $DBF.Write($Empty, 0, $Size)
    $DBF.WriteByte(0x1A)
    $DBF.SetLength($Offset + $Size + 1)
    $Count = [uint32]($DBFInfo.Header.NumRecords + 1)
    [void]$DBF.Seek(4, [IO.SeekOrigin]::Begin)
    [byte[]]$CountBytes = _UInt32BytesLE $Count
    $DBF.Write($CountBytes, 0, 4)
    $DBFInfo.Header.NumRecords = $Count
    _WriteDBFHeaderDate $DBFInfo
    $DBF.Flush()
    $null = _ReadRecord $DBFInfo $Count
}

function _CloseDBF ($DBFInfo) {
    if (_HasPendingDBFChanges $DBFInfo) { throw 'Unsaved changes; call SaveRecord before Close.' }
    if ($null -ne $DBFInfo.FilehandleOfMemo) {
        $DBFInfo.FilehandleOfMemo.Dispose()
        $DBFInfo.FilehandleOfMemo = $null
    }
    if ($null -ne $DBFInfo.FilehandleOfDBF) {
        $DBFInfo.FilehandleOfDBF.Dispose()
        $DBFInfo.FilehandleOfDBF = $null
    }
}
function _GoBottom ($DBFInfo) { $null = _ReadRecord $DBFInfo $DBFInfo.Header.NumRecords }
function _GoTop ($DBFInfo) { $null = _ReadRecord $DBFInfo 1 }
function _Skip ($DBFInfo, $SkipRecords) {
    if ($null -eq $SkipRecords) { $SkipRecords = 1 }
    $null = _ReadRecord $DBFInfo ($DBFInfo.RecNo + $SkipRecords)
}
function _Goto ($DBFInfo, $RecNo) { $null = _ReadRecord $DBFInfo $RecNo }

function _ListAll ($DBFInfo)
{
    1..$DBFInfo.Header.NumRecords
}

# Load a record and keep its original bytes. Unsupported field types are
# preserved byte-for-byte unless the caller explicitly tries to edit them.
function _ReadRecord ($DBFInfo, $recNo) {

	if (_HasPendingDBFChanges $DBFInfo) { throw 'Unsaved changes; call SaveRecord before navigating.' }
    # Do not leave a partially decoded record marked as loaded if a memo is corrupt.
    $DBFInfo.LoadedRecNo = 0
    $Target = $DBFInfo.RecNo
    if ($null -ne $recNo) { $Target = [long]$recNo }
    if ($Target -lt 1 -or $Target -gt $DBFInfo.Header.NumRecords) { throw "Invalid DBF record number: $Target" }
    $DBF = $DBFInfo.FilehandleOfDBF
    $Position = [long]$DBFInfo.Header.DataOffset + ([long]$Target - 1) * $DBFInfo.Header.RecordSize
    [void]$DBF.Seek($Position, [IO.SeekOrigin]::Begin)
    [byte[]]$RecordBuffer = _ReadExactly $DBF $DBFInfo.Header.RecordSize
    $DBFInfo.RecNo = $Target
    $DBFInfo.Deleted = ($RecordBuffer[0] -ne 0x20)
    $DBFInfo.OriginalRecord = [byte[]]$RecordBuffer.Clone()
    $DBFInfo.OriginalValues.Clear()
    $Culture = [Globalization.CultureInfo]::InvariantCulture
    foreach ($Field in $DBFInfo.Header.Fields) {
        $Offset = 1 + [int]$Field.FieldPos
        $Length = [int]$Field.Length
        $Value = $null
        switch ($Field.Type) {
            'C' { $Value = $DBFInfo.TextEncoding.GetString($RecordBuffer, $Offset, $Length) }
            'D' {
                if ($Length -eq 8) {
                    $Data = [Text.Encoding]::ASCII.GetString($RecordBuffer, $Offset, 8)
                    if ($Data.Trim().Length -eq 0) { $Value = [DateTime]::MinValue }
                    else { $Value = [DateTime]::ParseExact($Data, 'yyyyMMdd', $Culture) }
                }

            }
            'L' {
                if ($Length -eq 1) {
                    if ($RecordBuffer[$Offset] -in @(84,116,89,121)) { $Value = $true }
                    elseif ($RecordBuffer[$Offset] -in @(70,102,78,110)) { $Value = $false }
                }
            }
            'N' {
                $Data = [Text.Encoding]::ASCII.GetString($RecordBuffer, $Offset, $Length).Trim()
                if ($Data.Length -gt 0) { $Value = [decimal]::Parse($Data, [Globalization.NumberStyles]::Float, $Culture) }
            }
            'F' {
                $Data = [Text.Encoding]::ASCII.GetString($RecordBuffer, $Offset, $Length).Trim()
                if ($Data.Length -gt 0) { $Value = [decimal]::Parse($Data, [Globalization.NumberStyles]::Float, $Culture) }
            }
            'M' { $Value = _Get-MemofieldData $DBFInfo $Field.Name }
            default { } # unsupported formats are never re-serialized
        }
        $DBFInfo.Fields[$Field.Name] = $Value
        $DBFInfo.OriginalValues[$Field.Name] = $Value

    }
    
    # Only a fully decoded record is eligible for SaveRecord/dirty tracking.
    $DBFInfo.LoadedRecNo = $Target
    if ($null -ne $recNo) { return (New-Object PSObject -Property $DBFInfo.Fields) }
}

# retrieves the data of a given memo-field
function _Get-MemofieldData ($DBFInfo, $Fieldname)
{
    $retVal = ""

    if ($DBFInfo.Type.hasMemoFile)
    {
        if ($DBFInfo.FileHandleOfMemo)
        {        
            $FieldPos = $DBFInfo.Header.Fields | Where-Object {$_.Name -eq $Fieldname}
            if ($FieldPos)
            {
                if ($DBFInfo.Type.memoExt -eq "DBT")
                {
                    $retval = _Get-MemofieldDataDBT $DBFInfo $FieldPos
                }
                else
                {
                    $retval = _Get-MemofieldDataFPT $DBFInfo $FieldPos
                }                   
            }
        }
    }

    $retVal

}

function _Get-MemofieldDataDBT ($DBFInfo, $FieldPos)
{
    $retval = "_Get-MemofieldDataDBT() needs to be implemented!"
}

function _Get-MemofieldDataFPT ($DBFInfo, $FieldPos) {
    [uint32]$Pointer = _GetMemoBlockNumberFromField $DBFInfo $FieldPos
    if ($Pointer -eq 0) { return '' }
    $FPT = $DBFInfo.FilehandleOfMemo
    $Address = [long]$Pointer * [long]$DBFInfo.Type.memoBlockSize
    if ($Address -lt 8 -or $Address + 8 -gt $FPT.Length) { throw "Invalid FPT pointer in '$($FieldPos.Name)'." }
    [void]$FPT.Seek($Address, [IO.SeekOrigin]::Begin)
    $Header = _ReadExactly $FPT 8
    $Type = _UInt32BE $Header 0
    $Length = _UInt32BE $Header 4
    if ($Type -ne 1) { throw "FPT memo '$($FieldPos.Name)' is not a plain text memo (type $Type)." }
    if ($Length -gt [int]::MaxValue -or [uint64]$Length -gt ([uint64]$FPT.Length - [uint64]$FPT.Position)) {
        throw "Truncated FPT memo '$($FieldPos.Name)'."
    }

    $Bytes = _ReadExactly $FPT ([int]$Length)
    return $DBFInfo.TextEncoding.GetString($Bytes)
}

# FPT pointers can be 4-byte little-endian integers or 10-byte ASCII numbers.
function _GetMemoBlockNumberFromField ($DBFInfo, $FieldPos) {
    $Size = [int]$FieldPos.Length
    if ($Size -notin @(4,10)) { throw "Unsupported FPT memo pointer width $Size in '$($FieldPos.Name)'." }
    $Location = [long]$DBFInfo.Header.DataOffset + ([long]$DBFInfo.RecNo - 1) * $DBFInfo.Header.RecordSize + $FieldPos.FieldPos + 1
    [void]$DBFInfo.FilehandleOfDBF.Seek($Location, [IO.SeekOrigin]::Begin)
    $Bytes = _ReadExactly $DBFInfo.FilehandleOfDBF $Size
    if ($Size -eq 4) { return (_UInt32LE $Bytes 0) }
    $Text = [Text.Encoding]::ASCII.GetString($Bytes).Trim()
    if ($Text.Length -eq 0) { return [uint32]0 }
    if ($Text -notmatch '^\d{1,10}$') { throw "Invalid FPT pointer '$Text' in '$($FieldPos.Name)'." }
    return [uint32]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture)
}

# checks the integrity of the memofields in the current record
# it checks if the memofields are reachable an the memofield headertype is text
function _Check-MemofieldIntegrity ($DBFInfo)
{
    $retVal = @()

    if ($DBFInfo.Type.hasMemoFile)
    {
        if ($DBFInfo.FileHandleOfMemo)
        {
            $FieldPos = $DBFInfo.Header.Fields | Where-Object {$_.Type -eq "M"}
            foreach ($fp in $FieldPos)
            {                
                if ($DBFInfo.Type.memoExt -eq "DBT")
                {
                    $checkresult = _Check-MemofieldDataDBT $DBFInfo $fp
                }
                else
                {
                    $checkresult = _Check-MemofieldDataFPT $DBFInfo $fp
                }

                if ($checkresult -ne $null)
                {
                    $retval += $checkresult
                }
            }
        }
    }

    $retVal

}

function _Check-MemofieldDataDBT ($DBFInfo, $FieldPos)
{
    $retval = "_Get-MemofieldDataDBT() needs to be implemented!"
}

# Check the raw pointer and FPT memo header without reading or decoding the payload.
function _Check-MemofieldDataFPT ($DBFInfo, $FieldPos) {
    try {
        [uint32]$Pointer = _GetMemoBlockNumberFromField $DBFInfo $FieldPos
        if ($Pointer -eq 0) { return $null }
        $FPT = $DBFInfo.FilehandleOfMemo
        $BlockSize = [long]$DBFInfo.Type.memoBlockSize
        if ($null -eq $FPT -or $BlockSize -lt 8) { throw 'Missing FPT or invalid block size.' }
        $Address = [long]$Pointer * $BlockSize
        if ($Address -lt 8 -or $Address + 8 -gt $FPT.Length) {
            throw "FPT memo pointer out of range: $Pointer."
        }
        [void]$FPT.Seek($Address, [IO.SeekOrigin]::Begin)
        [byte[]]$Header = _ReadExactly $FPT 8
        $Type = _UInt32BE $Header 0
        [uint32]$PayloadLength = _UInt32BE $Header 4
        if ($Type -ne 1) { throw "Unexpected FPT memo block type $Type at block $Pointer." }
        if ([uint64]$PayloadLength -gt ([uint64]$FPT.Length - [uint64]$FPT.Position)) {
            throw "FPT memo at block $Pointer extends beyond the file."
        }
        return $null
    } catch {
        return [pscustomobject]@{ RecNo = $DBFInfo.RecNo; FieldPos = $FieldPos; Error = $_.Exception.Message }

    }
}

function _Reset-MemofieldPointer ($DBFInfo, $FieldName, $RecNo = $null)
{
    if (-not $DBFInfo.Type.hasMemoFile -or $DBFInfo.Type.memoExt -ne 'FPT') {
        throw 'Raw memo pointer reset currently supports FPT memo files only.'
     }
    $MatchingFields = @($DBFInfo.Header.Fields | Where-Object { $_.Type -eq 'M' -and $_.Name -eq $FieldName })
    if ($MatchingFields.Count -ne 1) { throw "Memo field '$FieldName' not found or ambiguous." }
    _Reset-MemofieldPointerFPT $DBFInfo $MatchingFields[0] $RecNo
}

# Repair operation: exactly the pointer bytes in the DBF, never the FPT.
# 10-byte ASCII pointer -> 10 spaces (legacy behaviour).
# 4-byte binary pointer -> 4 NUL bytes (zero block number).
function _Reset-MemofieldPointerFPT ($DBFInfo, $FieldPos, $RecNo = $null) {
    $DBF = $DBFInfo.FilehandleOfDBF
    if ($DBFInfo.ReadOnly -or $null -eq $DBF -or -not $DBF.CanWrite) {
        throw 'DBF opened read-only.'
    }
    if ($DBFInfo.Type.memoExt -ne 'FPT' -or $FieldPos.Type -ne 'M') {
        throw 'This is not an FPT memo field.'
    }
    if (_HasPendingDBFChanges $DBFInfo) { throw 'Save or discard pending edits before resetting a memo pointer.' }
    if ($null -eq $RecNo) { $RecNo = $DBFInfo.RecNo }
    $Target = [long]$RecNo
    if ($Target -lt 1 -or $Target -gt [long]$DBFInfo.Header.NumRecords) {
        throw "Invalid DBF record number: $Target"
    }
    $Width = [int]$FieldPos.Length
    if ($Width -notin @(4,10)) { throw "Unsupported FPT memo pointer width $Width." }
    $Position = [long]$DBFInfo.Header.DataOffset +
        ($Target - 1) * [long]$DBFInfo.Header.RecordSize +
        1 + [long]$FieldPos.FieldPos
    if ($Position -lt 0 -or $Position + $Width -gt $DBF.Length) {
        throw "DBF record $Target is truncated."
    }
    [byte[]]$EmptyPointer = _MemoPointerBytes $FieldPos ([uint32]0)
    [void]$DBF.Seek($Position, [IO.SeekOrigin]::Begin)
    [byte[]]$Before = _ReadExactly $DBF $Width
    $NeedsReset = $false
    for ($I = 0; $I -lt $Width; $I++) {
        if ($Before[$I] -ne $EmptyPointer[$I]) { $NeedsReset = $true; break }
    }
    if ($NeedsReset) {
        [void]$DBF.Seek($Position, [IO.SeekOrigin]::Begin)
        $DBF.Write($EmptyPointer, 0, $Width)
        $DBF.Flush()
    }
    # Invalidate a cached record so later updates must reload from the DBF.
    if ($DBFInfo.LoadedRecNo -eq $Target) {
        $DBFInfo.LoadedRecNo = 0
        $DBFInfo.OriginalRecord = $null
        $DBFInfo.OriginalValues.Clear()
        $DBFInfo.Fields[$FieldPos.Name] = ''
    }
}


# test
# $a=Use-DBF C:\delacdx\auftrag.dbf
# foreach($nr in 500..510) { $a.GoTo($nr); $a.Fields.Nummer; $a.Fields.Patient; $a.Fields.Patient.Length }
# $a.Close()

#
# possible syntax:
#
# $a.All().Where($_.Patient -eq "Müller")
# $a.Next(100).Where($_.Patient -eq "Müller")
#
# $a.Fields|where {$_.Nummer -eq "001004"}

# $daten = foreach($nr in $tr.ListAll()) {$tr.Goto($nr); new-object -property $tr.Fields -typename psobject}
#
# compare data:
# $diff=Compare-Object -ReferenceObject $orgbeb -DifferenceObject $trbeb -Property BEBart -PassThru

# getting all memofields
# $b.Header.Fields| where type -eq "M"

# checks memofield-integrity:
# foreach($nr in $b.ListAll()) {$b.Goto($nr); _Check-MemofieldIntegrity $b }

# clear all mispointing memofields, handles multiple memofields
# $b = Use-DBF (Resolve-Path .\artikel.dbf) -ReadWrite                                                            
# $bk = foreach($nr in $b.ListAll()) {$b.Goto($nr); _Check-MemofieldIntegrity $b }
# # $bk now holds a special structure of memofields to be repaired
# foreach ($r in $bk) {$b.GoTo($r.recno); _Reset-MemofieldPointer $b $r.FieldPos.Name}                                      
# $bkN = foreach($nr in $b.ListAll()) {$b.Goto($nr); _Check-MemofieldIntegrity $b }                                         
# $bkN.Length                                                                                                               
# $b.Close()  
#
#

# Zap_DBF C:\temp\PSDBFTest\temp\test.dbf
