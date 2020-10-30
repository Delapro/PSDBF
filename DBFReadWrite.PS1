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
    $DBFStructure | Add-Member -Type NoteProperty -Name Encoding -Value @()

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
    $DBFStructure.LastUpdate = New-Object System.DateTime($Year,$Month,$Day)

    $NumTemp = @(0x00) * 4

    # reading language driver byte also known as encoding
    $Position = $DBFFileHandle.Seek(29, [System.IO.SeekOrigin]::Begin)
    $BytesRead = $DBFFileHandle.Read($NumTemp, 0, 1)
    $DBFStructure.Encoding = ConvertLanguageDriver2CodePage -LanguageDriver (Bin2Int32 ($NumTemp))
    
    # calculating number of fields, 32 bytes header, 2 bytes end of data and 32 bytes per field definition
    $DBFStructure.NumFields = ($DBFStructure.DataOffset - 32 -2) / 32
    
    # reading field defintions
    $Position = $DBFFileHandle.Seek(32, [System.IO.SeekOrigin]::Begin)    
    $FNr = 1
    $Encode = [System.Text.Encoding]::GetEncoding(850)
    $FieldPos = 0
    while($FNr -le $DBFStructure.NumFields)
    {
        $NumTemp = @(0x00) * 32
        # reading field structure, per field 32bytes
        $BytesRead = $DBFFileHandle.Read($NumTemp, 0, 32)   
        $DBFFieldDef = New-Object PSObject
        $DBFFieldDef | Add-Member -Type NoteProperty -Name Nr -Value 1
        $DBFFieldDef | Add-Member -Type NoteProperty -Name Name -Value "Name"
        $DBFFieldDef | Add-Member -Type NoteProperty -Name Type -Value "C"
        $DBFFieldDef | Add-Member -Type NoteProperty -Name Length -Value 0
        $DBFFieldDef | Add-Member -Type NoteProperty -Name Decimal -Value 0
        $DBFFieldDef | Add-Member -Type NoteProperty -Name FieldPos -Value 0
        $DBFFieldDef.Nr = $FNr
        $DBFFieldDef.Name = $Encode.GetString($NumTemp[0..9]).TrimEnd(0)
        $DBFFieldDef.Type = $Encode.GetString($NumTemp[11])
        $DBFFieldDef.FieldPos = $FieldPos
        if ($DBFFieldDef.Type -eq "C")
        {
            # Clipper + FoxPro special case
            $DBFFieldDef.Length = $NumTemp[16] + $NumTemp[17] * 256
            $DBFFieldDef.Decimal = 0
        }
        else
        {
            $DBFFieldDef.Length = $NumTemp[16]
            $DBFFieldDef.Decimal = $NumTemp[17]
        }
        $FieldPos += $DBFFieldDef.Length
        $FNr++
        $DBFStructure.Fields += $DBFFieldDef
    }
    
    $DBFFileHandle.Close()
    
    $DBFStructure
    
}

function ConvertLanguageDriver2CodePage
{
    Param ([int]$LanguageDriver)

    # Details https://www.clicketyclick.dk/databases/xbase/format/dbf.html#DBF_NOTE_5_TARGET
    switch ($LanguageDriver) {
        1 {437}
        2 {850}
        3 {1252}
        # UTF-8?
    }
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

# opens a DBF-file with active record pattern
function Use-DBF () {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory=$true,
                   ValueFromPipeline=$true,
                   HelpMessage="Provide DBF-filename")]
        [string]$DBFFilename,
        [Parameter(Mandatory=$false,
                   HelpMessage="Open DBF in ReadWrite-mode")]
        [Switch]$ReadWrite=$false
         )

    $DBFInfo = New-Object PSObject
    _AddPropertiesAndMethods $DBFInfo

    $DBFInfo.Type = Test-DBF $DBFFilename
    $DBFInfo.Header = Get-DBFStructure $DBFFilename
    
    foreach ($field in $DBFInfo.Header.Fields)
    {
        # TODO: every field should get its own getter and setter function:
        # $DBFInfo.Fields | Add-Member -MemberType ScriptProperty -Name "Fieldname" -Value {$this.Fieldbuffer[Fieldname]} -SecondValue {Param($Value);$Value;$this.Fieldbuffer[Fieldname]=$Value}
        # there should also be a dirty flag if a field has changed 
        $DBFInfo.Fields[$field.Name] = "val"  # TODO: check val, better empty
    }
    
    if ($ReadWrite)
    {
        $DBFInfo.FilehandleOfDBF = [System.IO.File]::Open($DBFFilename,
                                            [System.IO.FileMode]::Open,
                                            [System.IO.FileAccess]::ReadWrite,
                                            [System.IO.FileShare]::ReadWrite)
    }
    else
    {
        $DBFInfo.FilehandleOfDBF = [System.IO.File]::Open($DBFFilename,
                                                        [System.IO.FileMode]::Open,
                                                        [System.IO.FileAccess]::Read,
                                                        [System.IO.FileShare]::ReadWrite)
    }

    if ($DBFInfo.Type.hasMemoFile)
    {
        $DBFInfo.FilehandleOfMemo = [System.IO.File]::Open([System.IO.Path]::ChangeExtension($DBFFilename, $DBFInfo.Type.MemoExt),
                                                            [System.IO.FileMode]::Open,
                                                            [System.IO.FileAccess]::Read,
                                                            [System.IO.FileShare]::ReadWrite)
    }
    
    $DBFInfo
}

# adds Properties and Methods to DBFInfo-Object
Function _AddPropertiesAndMethods {
    Param(
        $DBFInfo
    )

    $DBFInfo | Add-Member -Type NoteProperty -Name Header -Value $null
    $DBFInfo | Add-Member -Type NoteProperty -Name Type -Value $null
    $DBFInfo | Add-Member -Type NoteProperty -Name ReadOnly -Value ($ReadWrite -eq $false)
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
        131 {$DBFObject.Type = "DBF+DBT-files"; $DBFObject.hasMemoFile = $true}
        139 {$DBFObject.Type = "DBF(dBase IV)+DBT-files"; $DBFObject.hasMemoFile = $true}
        245 {$DBFObject.Type = "DBF+FPT-files"; $DBFObject.hasMemoFile = $true; $DBFObject.memoExt = "FPT"}
        default {$DBFObject.Type = "unknown"}
    }

    $DBFObject
}

# create new field definition
Function New-Field {
	[CmdletBinding()]
	Param (
        [String]$Name,
        [Validateset('Character', 'Logical', 'Numeric', 'Memo', 'Date')]
        [String]$Type,
        [int]$Length,
        [int]$Decimal
	)

	[PSCustomObject]@{
                        PSTypeName = "PSDBF.Field";
                        Name = $Name;
                        Type = $Type;
                        Length = $Length;
                        Decimal = $Decimal;
					 }
}

# opens a DBF-file with active record pattern
function New-DBF () {
    [CmdletBinding()]
    Param( 
        [Parameter(Mandatory=$true,
                   ValueFromPipeline=$true,
                   HelpMessage="Provide DBF-filename")]
        [string]$DBFFilename,
        [Parameter(Mandatory=$true,
        HelpMessage="DBF-fields structure")]
        [PSTypeName('PSDBF.Field')]
        $Fields
    )

    $ReadWrite = $true

    $DBFInfo = New-Object PSObject
    _AddPropertiesAndMethods $DBFInfo

    $hasMemofield = $false
    foreach ($field in $Fields)
    {
        # set default values depending on type of field
        switch ($field.type) {
            'C' {$DBFInfo.Fields[$field.Name] = ""}
            'D' {$DBFInfo.Fields[$field.Name] = (Get-Date).Date}
            'L' {$DBFInfo.Fields[$field.Name] = $false}
            'M' {$DBFInfo.Fields[$field.Name] = ""; $hasMemofield = $true}
            'D' {$DBFInfo.Fields[$field.Name] = 0}
        }
    }

    $DBFInfo.FilehandleOfDBF = [System.IO.File]::Open($DBFFilename,
                                            [System.IO.FileMode]::CreateNew,
                                            [System.IO.FileAccess]::ReadWrite,
                                            [System.IO.FileShare]::ReadWrite)

    # writing DBF-Header
    If ($hasMemofield) {
        # TODO: support DBT!
        $DbfHeaderByte = 245
    } else {
        $DbfHeaderByte = 3
    }
    $DBFInfo.FileHandleOfDBF.WriteByte($DbfHeaderByte)

    $DBFObject = _NewDBFObject -DBFType $DbfHeaderByte

    # writing number of fields
    
    # calculating number of fields, 32 bytes header, 2 bytes end of data and 32 bytes per field definition
    $DBFStructure.NumFields = ($DBFStructure.DataOffset - 32 -2) / 32
    
    # reading field defintions
    $Position = $DBFFileHandle.Seek(32, [System.IO.SeekOrigin]::Begin)    
    $FNr = 1
    $Encode = [System.Text.Encoding]::GetEncoding(850)
    $FieldPos = 0
    while($FNr -le $DBFStructure.NumFields)
    {
        $NumTemp = @(0x00) * 32
        # reading field structure, per field 32bytes
        $BytesRead = $DBFFileHandle.Read($NumTemp, 0, 32)   
        $DBFFieldDef = New-Object PSObject
        $DBFFieldDef | Add-Member -Type NoteProperty -Name Nr -Value 1
        $DBFFieldDef | Add-Member -Type NoteProperty -Name Name -Value "Name"
        $DBFFieldDef | Add-Member -Type NoteProperty -Name Type -Value "C"
        $DBFFieldDef | Add-Member -Type NoteProperty -Name Length -Value 0
        $DBFFieldDef | Add-Member -Type NoteProperty -Name Decimal -Value 0
        $DBFFieldDef | Add-Member -Type NoteProperty -Name FieldPos -Value 0
        $DBFFieldDef.Nr = $FNr
        $DBFFieldDef.Name = $Encode.GetString($NumTemp[0..9]).TrimEnd(0)
        $DBFFieldDef.Type = $Encode.GetString($NumTemp[11])
        $DBFFieldDef.FieldPos = $FieldPos
        if ($DBFFieldDef.Type -eq "C")
        {
            # Clipper + FoxPro special case
            $DBFFieldDef.Length = $NumTemp[16] + $NumTemp[17] * 256
            $DBFFieldDef.Decimal = 0
        }
        else
        {
            $DBFFieldDef.Length = $NumTemp[16]
            $DBFFieldDef.Decimal = $NumTemp[17]
        }
        $FieldPos += $DBFFieldDef.Length
        $FNr++
        $DBFStructure.Fields += $DBFFieldDef
    }


    $DBFInfo
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

function _AppendBlank ($DBFInfo)
{
    [System.Byte[]]$Numtemp=@()

    if ($DBFInfo.ReadOnly) { throw "file is readonly"} # $DbfInfo.Name}

    $DBFFileHandle = $DBFInfo.FileHandleOfDBF
    # append new Record 
    $RecordPos = $DBFInfo.Header.DataOffset + $DBFInfo.Header.NumRecords * $DBFInfo.Header.RecordSize
    $Position = $DBFFileHandle.Seek($RecordPos, [System.IO.SeekOrigin]::Begin)
    $EmptyRecord = [Byte[]]0x20*$DBFInfo.Header.RecordSize
    $DBFFileHandle.Write($EmptyRecord, 0, $DBFInfo.Header.RecordSize)

    # increase RecordCount
    $NumTemp=@(0x00)*4
    $Position = $DBFFileHandle.Seek(4, [System.IO.SeekOrigin]::Begin)
    $BytesRead = $DBFFileHandle.Read($NumTemp, 0, 4)
    $DBFInfo.Header.NumRecords = (Bin2Int32 $NumTemp) +1
    $NumTemp = Int322Bin $DBFInfo.Header.NumRecords
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
    $DBFInfo.Header.LastUpdate = $Date

    $FlushToDisk = $True
    $DBFFileHandle.Flush()
    $DBFFileHandle.Flush($FlushToDisk)

    # make the new record the current record
    _GoBottom($DBFInfo)
}

function _CloseDBF ($DBFInfo)
{
    if ($DBFInfo.FilehandleOfMemo -ne $null)
    {
        $this.FilehandleOfMemo.Close()
        $this.FilehandleOfMemo = $null
    }
    
    if ($DBFInfo.FilehandleOfDBF -ne $null)
    {
        $this.FilehandleOfDBF.Close()
        $this.FilehandleOfDBF = $null
    }
}

function _GoBottom ($DBFInfo)
{
    $DBFInfo.RecNo = $DBFInfo.Header.NumRecords
    _ReadRecord $DBFInfo
}

function _GoTop ($DBFInfo)
{
    $DBFInfo.RecNo = 1
    _ReadRecord $DBFInfo
}

function _Skip ($DBFInfo, $SkipRecords)
{
    $Rel = 1

    if ($SkipRecords -ne $null)
    {
        $Rel = $SkipRecords
    }
        
    $DBFInfo.RecNo += $Rel
    _ReadRecord $DBFInfo

}

function _Goto ($DBFInfo, $RecNo)
{
    $DBFInfo.RecNo = $RecNo
    _ReadRecord $DBFInfo
}

function _ListAll ($DBFInfo)
{
    1..$DBFInfo.Header.NumRecords
}

# refreshes the current fieldvalues in the fields hashset
function _ReadRecord ($DBFInfo, $recNo)
{

    if ($recNo -ne $null) 
    { 
        $DBFInfo.RecNo = $RecNo
    }

    $Culture = New-Object System.Globalization.CultureInfo "en-us"
    #$Encode = New-Object System.Text.ASCIIEncoding
    $Encode = [System.Text.Encoding]::GetEncoding(850)
    [System.Byte[]]$RecordBuffer = @(0x20) * $DBFInfo.Header.RecordSize
    $RecordPos = $DBFInfo.Header.DataOffset + ($DBFInfo.RecNo -1) * $DBFInfo.Header.RecordSize
    #if ($RecordPos -le 
    $Position = $DBFInfo.FilehandleOfDBF.Seek($RecordPos, [System.IO.SeekOrigin]::Begin)    
    $BytesRead = $DBFInfo.FilehandleOfDBF.Read($RecordBuffer, 0, $DBFInfo.Header.RecordSize)
    #if ($Position -gt 0)
    
    $DBFInfo.Deleted = $RecordBuffer[0] -ne 32
    
    foreach ($field in $DBFInfo.Header.Fields)
    {

        switch ($field.Type)
        {
            "C" { 
                    $DBFInfo.Fields[$field.Name] = $Encode.GetString($RecordBuffer[($field.FieldPos+1)..($field.FieldPos + $field.Length)]) 
                }

            "D" { 
                    $Year=$Encode.GetString($RecordBuffer[($field.FieldPos+1)..($field.FieldPos + 4)])
                    $Month=$Encode.GetString($RecordBuffer[($field.FieldPos+5)..($field.FieldPos + 6)])
                    $Day=$Encode.GetString($RecordBuffer[($field.FieldPos+7)..($field.FieldPos + 8)])
                    if ($Year.Trim().Length -eq 0)
                    {
                    $DBFInfo.Fields[$field.Name] = [System.DateTime]::Minvalue
                    }
                    else
                    {
                    $DBFInfo.Fields[$field.Name] = New-Object System.DateTime($Year,$Month,$Day)
                    }
                }

            "L" { 
                    $DBFInfo.Fields[$field.Name] = $RecordBuffer[($field.FieldPos+1)] -eq 84 #"T"
                }

            "N" { 
                    $Data=$Encode.GetString($RecordBuffer[($field.FieldPos+1)..($field.FieldPos + $field.Length)])
                    if($Data.Trim().Length -eq 0)
                    {
                        $Data = "0.0"
                    }
                    $DBFInfo.Fields[$field.Name] = [Convert]::ToDouble($Data,$Culture)
                }

            "M" { 
                    $Data = _Get-MemofieldData $DBFInfo $field.Name
                    $DBFInfo.Fields[$field.Name] = $Data 
                }
        }
    }
    
    if ($recNo -ne $null) 
    { 
        new-object PSObject -Property $DBFInfo.Fields        
    }

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

function _Get-MemofieldDataFPT ($DBFInfo, $FieldPos)
{

    $retVal = ""
    $MemoPointer = _GetMemoBlockNumberFromField $DBFInfo $FieldPos

    #$MemofieldSize = 10    
    #$Encode = [System.Text.Encoding]::GetEncoding(850)
    #[System.Byte[]]$MemoFieldBuffer = @(0x20) * $MemofieldSize
    #$RecordFieldPos = $DBFInfo.Header.DataOffset + ($DBFInfo.RecNo -1) * $DBFInfo.Header.RecordSize + $FieldPos.FieldPos +1
    #$Position = $DBFInfo.FilehandleOfDBF.Seek($RecordFieldPos, [System.IO.SeekOrigin]::Begin)    
    #$BytesRead = $DBFInfo.FilehandleOfDBF.Read($MemoFieldBuffer, 0, $MemofieldSize)
    #$MemoPointer = $Encode.GetString($MemoFieldBuffer)

    if ($MemoPointer.Trim().Length -gt 0)
    {
        $MemoPointer = [System.Convert]::ToInt32($MemoPointer)
        $MemoPointer = $MemoPointer * $DBFInfo.Type.memoBlockSize
        [System.Byte[]]$MemoFieldHeaderBuffer = @(0x0) * 4
        $Position = $DBFInfo.FilehandleOfMemo.Seek($MemoPointer, [System.IO.SeekOrigin]::Begin)
        $BytesRead = $DBFInfo.FilehandleOfMemo.Read($MemoFieldHeaderBuffer, 0, 4)

        #check if it's a text memo entry
        if ((Compare-Object $MemoFieldHeaderBuffer @(0,0,0,1)).length -eq 0)
        {
            # get the length of the memofield
            $BytesRead = $DBFInfo.FilehandleOfMemo.Read($MemoFieldHeaderBuffer, 0, 4)
            $MemoFieldLength = $MemoFieldHeaderBuffer[0]*256*256*256+$MemoFieldHeaderBuffer[1]*256*256+$MemoFieldHeaderBuffer[2]*256+$MemoFieldHeaderBuffer[3]

            #read the memofield data
            [System.Byte[]]$MemoFieldBuffer = @(0x20) * $MemoFieldLength
            $BytesRead = $DBFInfo.FilehandleOfMemo.Read($MemoFieldBuffer, 0, $MemoFieldLength)
            $retVal = $Encode.GetString($MemoFieldBuffer)
        }
    }

    $retVal
}

# retrieves the Pointer to the Block in the memofile
function _GetMemoBlockNumberFromField ($DBFInfo, $FieldPos)
{
    $MemofieldSize = 10
    $Encode = [System.Text.Encoding]::GetEncoding(850)  # http://en.wikipedia.org/wiki/Code_page_850
    [System.Byte[]]$MemoFieldBuffer = @(0x20) * $MemofieldSize
    $RecordFieldPos = $DBFInfo.Header.DataOffset + ($DBFInfo.RecNo -1) * $DBFInfo.Header.RecordSize + $FieldPos.FieldPos +1
    $Position = $DBFInfo.FilehandleOfDBF.Seek($RecordFieldPos, [System.IO.SeekOrigin]::Begin)    
    $BytesRead = $DBFInfo.FilehandleOfDBF.Read($MemoFieldBuffer, 0, $MemofieldSize)
    $MemoPointer = $Encode.GetString($MemoFieldBuffer)

    $MemoPointer
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

function _Check-MemofieldDataFPT ($DBFInfo, $FieldPos)
{

    $retVal = $null
    $MemoPointer = _GetMemoBlockNumberFromField $DBFInfo $FieldPos

    if ($MemoPointer.Trim().Length -gt 0)
    {
        $MemoPointer = [System.Convert]::ToInt32($MemoPointer)
        $MemoPointer = $MemoPointer * $DBFInfo.Type.memoBlockSize
        [System.Byte[]]$MemoFieldHeaderBuffer = @(0x0) * 4
        $Position = $DBFInfo.FilehandleOfMemo.Seek($MemoPointer, [System.IO.SeekOrigin]::Begin)
        $BytesRead = $DBFInfo.FilehandleOfMemo.Read($MemoFieldHeaderBuffer, 0, 4)

        #check if it's a text memo entry
        if ((Compare-Object $MemoFieldHeaderBuffer @(0,0,0,1)).length -eq 0)
        {
            # get the length of the memofield
            $BytesRead = $DBFInfo.FilehandleOfMemo.Read($MemoFieldHeaderBuffer, 0, 4)
            $MemoFieldLength = $MemoFieldHeaderBuffer[0]*256*256*256+$MemoFieldHeaderBuffer[1]*256*256+$MemoFieldHeaderBuffer[2]*256+$MemoFieldHeaderBuffer[3]

            #read the memofield data
            [System.Byte[]]$MemoFieldBuffer = @(0x20) * $MemoFieldLength
            $BytesRead = $DBFInfo.FilehandleOfMemo.Read($MemoFieldBuffer, 0, $MemoFieldLength)
            #$retVal = $Encode.GetString($MemoFieldBuffer)
        }
        else
        {
            $Integrity = New-Object PSObject
            $Integrity | Add-Member -Type NoteProperty -Name RecNo -Value $DBFInfo.RecNo
            $Integrity | Add-Member -Type NoteProperty -Name FieldPos -Value $FieldPos
            $Integrity | Add-Member -Type NoteProperty -Name HeaderBytes -Value $MemoFieldHeaderBuffer
            $retval = $Integrity
            #Write-Host  $FieldPos.Name " Unknown Memofield-Header: $MemoFieldHeaderBuffer"
        }
    }

    $retVal
}

function _Reset-MemofieldPointer ($DBFInfo, $FieldName)
{
    $retVal = ""

    if ($DBFInfo.Type.hasMemoFile)
    {
        if ($DBFInfo.FileHandleOfMemo)
        {
            $FieldPos = $DBFInfo.Header.Fields | Where-Object {$_.Type -eq "M" -and $_.Name -eq $FieldName}
            foreach ($fp in $FieldPos)
            {                
                if ($DBFInfo.Type.memoExt -eq "DBT")
                {
                    $retval = _Reset-MemofieldPointerDBT $DBFInfo $fp
                }
                else
                {
                    $retval = _Reset-MemofieldPointerFPT $DBFInfo $fp
                }                   
            }
        }
    }

    $retVal

}

function _Reset-MemofieldPointerFPT ($DBFInfo, $FieldPos)
{

    $MemofieldSize = 10
    [System.Byte[]]$MemoFieldBuffer = @(0x20) * $MemofieldSize
    $RecordFieldPos = $DBFInfo.Header.DataOffset + ($DBFInfo.RecNo -1) * $DBFInfo.Header.RecordSize + $FieldPos.FieldPos +1
    $Position = $DBFInfo.FilehandleOfDBF.Seek($RecordFieldPos, [System.IO.SeekOrigin]::Begin)    
    $BytesRead = $DBFInfo.FilehandleOfDBF.Write($MemoFieldBuffer, 0, $MemofieldSize)

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
