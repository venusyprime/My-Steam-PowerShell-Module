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
                }
                if ($AppID) {Write-Verbose "AppID is $AppID";$dir = $dir | where Name -like "*_$($AppID).acf"}
                $dir
            } @paramsandpath
        }

        $convertedall = ConvertFrom-SteamFile -Path $manifests.FullName @params
        $objects = foreach ($converted in $convertedall) {
            $manifest = $manifests | where Name -Like "*_$($converted.AppID).acf"         
            $AppInstallDir = $converted.AppInstallDir
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
                Name = $Converted.Name
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
    } 
}