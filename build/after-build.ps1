﻿param(
    [Parameter(Mandatory=$true, Position = 0)][string]$BinariesDirectory,
    [Parameter(Mandatory=$true, Position = 1)][string]$BuildVersion,
    [Parameter(Mandatory=$true, Position = 2)][string]$BuildDefinitionName
)

function Get-VersionNumber
{
    $versionSplit = $BuildVersion.Replace($BuildDefinitionName, "").Split("_", [System.StringSplitOptions]::RemoveEmptyEntries);
    
    if ($versionSplit.Count -eq 0)
    {
        return [string]::Empty
    }
    else
    {
        # Semantic Versioning in NuGet does not support a format of yymmdd.rr, so we remove the dot notation.
        return $versionSplit[0].Replace(".","")
    }
}

function Expand-ReplacementToken([string]$Contents, [string]$Token, [string]$ReplaceWith)
{
    $replaced = $Contents.Replace($Token, $ReplaceWith)
    return $replaced
}

function Expand-ZipFile([string]$Archive, [string]$Destination)
{
    if (Test-Path $Destination)
    {
        Remove-Item $Destination -Recurse -Force 
    }

    New-Item $Destination -ItemType Directory | Out-Null

    $shell = New-Object -com shell.application
    $zip = $shell.NameSpace($Archive)
    
    foreach($item in $zip.items())
    {
        $shell.Namespace($destination).copyhere($item)
    }
}

function Replace-NuspecTokens($ProjectOutputDirectory, $NuspecFile)
{
    $buildConfiguration = $ProjectOutputDirectory.Name
    $fileContents = Get-Content $NuspecFile -ErrorAction Stop
    
    $result = Expand-ReplacementToken $fileContents '$configuration$' $buildConfiguration

    $result | Set-Content $NuspecFile
}

function Get-ProjectName($NuGetPackage)
{
    if ($NuGetPackage.BaseName -match '(?<projectname>[a-zA-Z\.]+)\.(?<version>[0-9\.]+(\-\w+)?)')
    {
        return $Matches['projectname']
    }
    else
    {
        Write-Error "[$($NuGetPackage.BaseName)] should have matched the Regex!"
        return $null
    }
}

function Invoke-DownloadNuget([string]$OutputDirectory)
{
    if (!(Test-Path $OutputDirectory))
    {
        New-Item $OutputDirectory -ItemType Directory | Out-Null
    }

    $nugetExe = Join-Path $OutputDirectory "nuget.exe"

    Invoke-WebRequest "http://www.nuget.org/nuget.exe" -OutFile $nugetExe -ErrorAction Stop

    return $nugetExe
}

$versionNumber = Get-VersionNumber

$nugetDirectory = Join-Path $env:TEMP $(Get-Random)
$nugetExe = Invoke-DownloadNuget $nugetDirectory

# For each project we want to get the nupkgs and for each of them:
# 1) Unpack the .nupkg
# 2) Merge the corresponding .nuspec with the .nuspec in the .nupkg
# 3) Repack the .nupkg with the signed dlls
foreach ($projectDirectory in $(Get-ChildItem $BinariesDirectory | ? { $_.PSIsContainer }))
{
    $allNupkgs = Get-ChildItem $projectDirectory.FullName -Recurse | ? { $_.Extension -eq '.nupkg' -and !$_.Name.Contains("symbols") }
    
    foreach ($nupkg in $allNupkgs)
    {
        $projectName = Get-ProjectName $nupkg
        $originalNuspec = Join-Path $PSScriptRoot "$projectName.nuspec"

        if (!(Test-Path $originalNuspec))
        {
            Write-Host "A template nuspec does not exist for the project [$projectName], skipping unpacking... Template [$originalNuspec]"
            continue
        }
        
        $tempDirectory = Join-Path $env:TEMP $(Get-Random)
        $unzippedDirectory = Join-Path $tempDirectory "Unzipped"
        $zipFile = Join-Path $tempDirectory "$($nupkg.BaseName).zip"

        # Expand-ZipFile only works with .zip
        New-Item $tempDirectory -ItemType Directory | Out-Null
        Copy-Item $nupkg.FullName $zipFile

        $resultingNuspecFile = Join-Path $projectDirectory.FullName "$projectName.nuspec"
        
        Copy-Item $originalNuspec $resultingNuspecFile

        Expand-ZipFile $zipFile $unzippedDirectory -ErrorAction Stop
    
        # Getting both .nuspec files, the template and the one from kpm build to merge.
        $sourceNuspecFile = Get-ChildItem $unzippedDirectory -Recurse -Include *.nuspec
        if (@($sourceNuspecFile).Count -ne 1)
        {
            Write-Error "ERROR: There should be 1 nuspec file in [$tempDirectory]! Actual [$sourceNuspecFile]"
            continue
        }

        $sourceNuspecFile = $sourceNuspecFile | select -First 1

        Replace-NuspecTokens $projectDirectory $resultingNuspecFile
    
        Add-VersionToNuspec $sourceNuspecFile.FullName $versionNumber

        Join-XmlFiles -Source $sourceNuspecFile.FullName -Template $resultingNuspecFile -Result $resultingNuspecFile

        # Move the original nupkgs and its symbol into another folder.
        $originalNupkgsDirectory = Join-Path $projectDirectory.FullName "originalnupkgs"
        
        if (!(Test-Path $originalNupkgsDirectory -PathType Container))
        {
            New-Item $originalNupkgsDirectory -ItemType Directory | Out-Null
        }

        $nupkg | Move-Item -Destination $originalNupkgsDirectory
        
        $nupkgSymbol = Join-Path $nupkg.Directory "$($nupkg.BaseName).symbols$($nupkg.Extension)"
        $nupkgSymbol | Move-Item -Destination $originalNupkgsDirectory

        $symbolPackage = Join-Path $nupkg.Directory "$($nupkg.BaseName).symbols$($nupkg.Extension)"
        $symbolPackage | Move-Item -Destination $originalNupkgsDirectory

        # Finally, repack all of the contents of the nupkg.
        Invoke-Expression "$nugetExe pack $resultingNuspecFile -OutputDirectory $($projectDirectory.FullName) -Symbols" -ErrorAction Stop

        # Cleaning up after ourselves...
        Remove-Item $resultingNuspecFile -Force
        Remove-Item $tempDirectory -Recurse -Force
    }
}

# Remove the downloaded nuget.exe
Remove-Item $nugetDirectory -Recurse -Force
