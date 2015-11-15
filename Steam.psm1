function Get-SteamPath {
    [CmdletBinding()]
    param(
        [string[]]$ComputerName = $env:COMPUTERNAME
    )
    foreach ($computer in $ComputerName) {
        if (($computer -eq ".") -or ($computer -eq "localhost") -or ($computer -eq $env:COMPUTERNAME)) {$params = @{}}
        else {$params = @{ComputerName = $computer}}
         
        $steamregistry = Invoke-Command -ScriptBlock {Get-ItemProperty HKCU:\SOFTWARE\Valve\Steam} @params
        $SteamPath = $steamregistry.SteamPath
        if ($SteamPath -like "*/*") {$steampath = $SteamPath.Replace("/","\")}
        [PSCustomObject]@{
            Name = "SteamPath";
            Path = $SteamPath
            PSComputerName = $computer
        }
        $configvdf = ConvertFrom-SteamFile -Path "$SteamPath\config\config.vdf" @params
        $otherlibrarylocations = $configvdf | Get-Member | Where Name -Like "BaseInstallFolder*"
        foreach ($otherlibrarylocation in $otherlibrarylocations) {
            $Name = $otherlibrarylocation.Name
            $value = $configvdf.$Name
            $folder = $value.Replace("\\","\")
            [PSCustomObject]@{
                Name = $Name
                Path = $folder
                PSComputerName = $computer
            }    
        }
    }
}
function Get-SteamGame {
    [CmdletBinding(DefaultParameterSetName="All")]
    param(
        [Parameter(ParameterSetName="Name",Position=0)]
        [string]$Name,
        [Parameter(ParameterSetName="AppID",Position=0)]
        [int32]$AppID,
        [Parameter(ParameterSetName="All")]
        [switch]$All,
        [string[]]$ComputerName = $env:COMPUTERNAME
    )
    foreach ($computer in $ComputerName) {
        if (($computer -eq ".") -or ($computer -eq "localhost") -or ($computer -eq $env:COMPUTERNAME)) {Write-Verbose "Looking at $env:computername, not creating PSSession";$params = @{}}
        else {Write-Verbose "Looking at $computer, creating PSSession";$session = New-PSSession $computer;$params = @{Session=$session}}


        $steampath = (Get-SteamPath -ComputerName $computer).Path
        $manifests = foreach ($path in $steampath) {
#            if (!$Name) {$name = ""}
#            if (!$AppID) {$AppID = ""}            
            $paramsandpath =  $params + @{ArgumentList=$Path,$Name,$AppID}
            Invoke-Command {
                param(
                    $path,
                    $Name,
                    $AppID
                )
                $dir = Get-ChildItem "$path\steamapps\AppManifest*.acf"
                if ($Name) {
                    Write-Verbose "Name is $name"
                    $select = $dir | select-string $Name
                    $pathtemp = $select.Path | select -Unique
                    $dir = foreach ($file in $pathtemp) {$dir | where FullName -eq $file}
                    if ($dir -eq $null) {Write-Error "No games found in local Steam libraries that match Name $name."}
                }
                if ($AppID) {
                    Write-Verbose "AppID is $AppID"
                    $dir = $dir | where Name -like "*_$($AppID).acf"
                    if ($dir -eq $null) {Write-Error "No games found in local Steam libraries that match AppID $AppID."}
                }
                $dir
            } @paramsandpath
        }

        $convertedall = ConvertFrom-SteamFile -Path $manifests.FullName @params
        $objects = foreach ($converted in $convertedall) {
            $converted = $converted.AppState
            
            [string]$Name = $converted.Name
            if ($Name -eq "AppState") {$name = $converted.UserConfig.Name}
            $manifest = $manifests | where Name -Like "*_$($converted.AppID).acf"         
            
            $AppInstallDir = $converted.UserConfig.AppInstallDir
            if ($AppInstallDir -eq $null) {
                $InstallDirBase = $converted.InstallDir
                if ($installdirbase -like "*\*") {$InstallDir = $InstallDirBase.Replace("\\","\")}
                else {$InstallDir = "$($Manifest.DirectoryName)\Common\$InstallDirBase"}
            }
            if ($AppInstallDir -ne $null) {$InstallDir = $AppInstallDir.Replace("\\","\")}

            $LastUpdatedUnix = $converted.LastUpdated
            $LastUpdatedDateTime = (Get-Date 01/01/1970).AddSeconds($LastUpdatedUnix)
            $SizeOnDiskBytes = $converted.SizeOnDisk
            [double]$SizeOnDiskMB = "{0:N2}" -f ($SizeOnDiskBytes/1MB)

            $object = [PSCustomObject]@{
                Name = $Name
                AppID = $Converted.AppID
                LastUpdated = $LastUpdatedDateTime
                SizeOnDisk = $SizeOnDiskMB
                Path = $InstallDir
                PSComputerName = $computer
            }
            $object
        }
        
        switch ($PSCmdlet.ParameterSetName) {
            "All" {$objects}
            "Name" {$objects | where Name -match $Name}
            "AppID" {$objects | where AppID -eq $AppID}
        }
    }
    if ($session) {$session | Remove-PSSession}
}

function ConvertFrom-SteamFile {
    [CmdletBinding(DefaultParameterSetName = "ComputerName")]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Path,
        [Parameter(ParameterSetName = "ComputerName")]
        [string]$ComputerName = $env:COMPUTERNAME,
        [Parameter(ParameterSetName = "PSSession")]
        $Session
    )
    switch ($PSCmdlet.ParameterSetName) {
        "ComputerName" {
            if (($ComputerName -eq ".") -or ($ComputerName -eq "localhost") -or ($ComputerName -eq $env:COMPUTERNAME)) {$params = @{}}
            else {$params = @{ComputerName = $computer}}
        }
        "PSSession" {$params = @{Session = $Session}}
    }
    $params =  $params + @{ArgumentList=(,$Path)}

    Invoke-Command @params -ScriptBlock {
        $path = Get-ChildItem $args[0]
        Write-Verbose "Path is $path"
        foreach ($item in $path) {
            Write-Verbose "Looking at $item on $env:computername."
            $content = Get-Content $item
            if ($content -ne "") {
                $idarray = [ordered]@{}
                $var1 = 0
                $content2 = foreach ($line in $content) {
                    if (($line.Contains('"')) -eq $true) {
                        $split = $line.Split('"')
                        $name = $line.Split('"')[1]
                        #bugfix: cannot have a number as an ID name
                        foreach ($number in 0..9) {
                            if ($name -like "$number*") {$name = "ID_$name"}
                        }
                        switch ($split.Count) {
                            3 {
                                #if test is here for any in the format "name" 1
                                if ($split[2] -eq "") {
                                    "<$name>"
                                    #Write-Warning "Writing $name to IDArray"
                                    $idarray = $idarray+@{$var1 = "</$name>"}
                                    $var1++
                                }
                                else {$value = $split[2].Trim(" ");"<$name>"+$value+"</$name>"}
                            }
                            5 {
                                $value = $split[3]
                                "<$name>"+$value+"</$name>"
                            }
                        }
                    }
                    else {$line}
                }
                $idarraytemp = $idarray.GetEnumerator()
                $matches_open = $content2 | select-string "{" | select Line,LineNumber
                $matches_closed = $content2 | select-string "}" | select Line,LineNumber
                $content3 = $content2

                foreach ($match in $matches_open) {
                        $linenumber = $match.LineNumber - 1
                        $line = $match.Line.Replace("{","}")
    
                        $closedline = $matches_closed | where Line -eq $Line | select -First 1
                        $closedlinenumber = $closedline.LineNumber - 1
                        $id = $idarraytemp | select -First 1

                        $content3[$linenumber] = ""
                        $content3[$closedlinenumber] = $id.Value
                        $matches_closed = $matches_closed | where LineNumber -ne $closedLine.LineNumber
                        $idarraytemp = $idarraytemp | where Name -ne $id.Name
                        Write-Verbose "Open:  $linenumber, ID: $($content3[$linenumber-1])"
                        Write-Verbose "Close: $closedlinenumber, ID $($id.value)"
                }
                #bugfix: for steam files that have no root node
                Write-Debug "Before content3 becomes a string"
                $content3 = @"
<xml>
$($content3 | Out-String)
</xml>
"@
                Write-Debug "before ampersand replacement"
                $content3 = $content3.Replace("&","&amp;")
                $xml = [xml]$content3
                $XML.Xml
            }
            if ($content -eq "") {Write-Warning "$item is null or empty."}


        <#
        foreach ($item in $path) {
            Write-Verbose "Looking at $item on $env:computername."
            $content = Get-Content $item
            if ($content -ne "") {
                $object = [PSCustomObject]@{}
                foreach ($entry in $content) {
                    if ($entry -like '*"*') {
                        $Name = $entry.Split('"')[1]
                        $Value = $entry.Split('"')[3]
            
                        try {$object | Add-Member -MemberType NoteProperty -Name $Name -Value $value -Force}
                        catch {Write-Verbose "Failed to add $Name to object, value likely already exists."}
                    }
                }
                $object #| Select-Object -Property * -Unique
            }
            if ($content -eq "") {Write-Warning "$item is null or empty."}
        }
        #>  
        }
    } 
}