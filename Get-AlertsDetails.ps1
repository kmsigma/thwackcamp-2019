<#
.Synopsis
   This script will get all alerts that /could/ be triggered for a specific monitored element
.DESCRIPTION
   The script queries the SolarWinds Information Service (SWIS) for all Nodes, Interfaces, and
Volumes.  It then asks the API for what alerts can be triggered from those elements.
.EXAMPLE
   ./Get-AlertDetails.ps1

   NodeID          : 8
   Caption         : NOCSERVU01v
   IPAddress       : 10.196.3.83
   Vendor          : Windows
   SubElID         : 9
   SubElName       : NOCSERVU01v - Ethernet
   SubElType       : Interface
   SubElTypeDesc   : Ethernet
   AlertName       : High Transmit Percent Utilization
   Description     : This alert writes to the SolarWinds event log when the current percent
                     utilization on the transmit side of an interface rises above 75% or
                     drops back down below 50%.
   Severity        : Critical
   ResponsibleTeam :
.INPUTS
   [None]
.OUTPUTS
   Custom PowerShell Object with the NodeID, Caption, IP Address, Vendor, SubElementID,
SubElement Name, SubElementType, SubElement Description, Alert Name, Alert Description,
Severity, and any Custom Properties bond to alerts.
.NOTES
   Name:      Get-AlertDetails.ps1
   Author(s): Leon Adato and Kevin M. Sparenberg
   Codename:  Project Windmill [https://binged.it/2LZGu6a]
   Version History:  
     0.1.0 ~ March 2019 - Initial plan and testing with URI call.
     0.2.0 ~ April 2019 - Expanded to include interfaces and volumes.
     0.3.0 ~ June 2019  - Converted SWQL queries to more generic formatting (for future expansion)
     0.4.0 ~ June 2019  - Corrected 
.COMPONENT
   THWACKcamp 2019
.FUNCTIONALITY
   Helps answer the question: What *could* alert on my system?
#>


#region Check for SwisPowerShell Module
if ( -not ( Get-Module -List -Name SwisPowerShell ) )
{
    Write-Error -Message "This script requires the SolarWinds Information Service PowerShell Module." -RecommendedAction "Exectute 'Install-Module -Name SwisPowerShell -Scope AllUsers -Force' from an Administrative PowerShell and try again."
    break
}
#endregion Check for SwisPowerShell Module



$Sw = New-Object -TypeName System.Diagnostics.Stopwatch
Write-Host -Object "Kicking off the stopwatch"
$Sw.Start()

#region Variable Definition
$OrionServer   = "ORIONSERVER" # IP or FQDN of your Orion Server or Orion Additional Web Site
$OrionUsername = "admin"       # Assuming traditional database logins
$OrionPassword = "Password"    # Password for above as above
$PageSize      = 10            # Maximum number of alerts to retrieve for each element

# Limiting selection (used for performance testing)
$UseTop        = $false
$Top           = 10

# Debug running?
$Debug         = $true
$DebugSize     = 10

# Build an empty collection for the alert details
$AlertDetails  = @()
# this might need to be "https" for your environment
$GetAlertsUri  = "http://$( $OrionServer )/api/AllAlertThisObjectCanTrigger/GetAlerts"
#endregion Variable Definition

#region SWIS Queries
# Nodes Query
$queryNodes = @"
SELECT$( if ( $UseTop ) { " TOP $Top" } ) N.NodeID
     , N.Caption
     , N.IPAddress
     , N.Vendor
     , N.Uri
     , N.InstanceType
     , '' AS SubElID
     , '' AS SubElName
     , '' AS SubElType
     , '' AS SubElTypeDesc
FROM Orion.Nodes AS N
"@

# Interfaces Query
$queryInterfaces = @"
SELECT$( if ( $UseTop ) { " TOP $Top" } ) N.NodeID
     , N.Caption
     , N.IPAddress
     , N.Vendor
     , I.Uri
     , I.InstanceType
     , I.InterfaceID AS SubElID
     , I.FullName AS SubElName
     , 'Interface' AS SubElType
     , I.TypeDescription AS SubElTypeDesc
FROM Orion.NPM.Interfaces AS I
JOIN Orion.Nodes AS N
   ON I.NodeID = N.NodeID
"@

# Volumes Query
$queryVolumes = @"
SELECT$( if ( $UseTop ) { " TOP $Top" } ) N.NodeID
      , N.Caption
      , N.IPAddress
      , N.Vendor
      , V.Uri
      , V.InstanceType
      , V.VolumeID AS SubElID
      , V.FullName AS SubElName
      , 'Volume' AS SubElType
      , V.Type AS SubElTypeDesc
FROM Orion.Volumes AS V
JOIN Orion.Nodes AS N
   ON V.NodeID = N.NodeID
"@
#endregion SWIS Queries

#region Connect to SolarWinds Information Service
Write-Host -Object "[Elapsed: $( $sw.Elapsed )] Building connection to SolarWinds Information Service"
$SwisConnection = Connect-Swis -Hostname $OrionServer -UserName $OrionUsername -Password $OrionPassword
#endregion Connect to SolarWinds Information Service


#region Query Nodes and store as $EntityList
Write-Host -Object "[Elapsed: $( $sw.Elapsed )] Querying Nodes"
Write-Verbose -Message "Executing SWQL Query: $queryNodes"
$EntityList  = Get-SwisData -SwisConnection $SwisConnection -Query $queryNodes
#endregion Query Nodes and store as $EntityList

#region Query Interfaces and add to existing $EntityList
Write-Host -Object "[Elapsed: $( $sw.Elapsed )] Querying Interfaces"
Write-Verbose -Message "Executing SWQL Query: $queryInterfaces"
$EntityList += Get-SwisData -SwisConnection $SwisConnection -Query $queryInterfaces
#endregion Query Interfaces and add to existing $EntityList

#region Query Volumes and add to existing $EntityList
Write-Host -Object "[Elapsed: $( $sw.Elapsed )] Querying Volumes"
Write-Verbose -Message "Executing SWQL Query: $queryVolumes"
$EntityList += Get-SwisData -SwisConnection $SwisConnection -Query $queryVolumes
#endregion Query Volumes and add to existing $EntityList

# We no longer need the SWIS connection, since the rest will be done with direct web calls
Remove-Variable -Name SwisConnection -ErrorAction SilentlyContinue


if ( $Debug )
{
    # If we are running in with $Debug on, then let's just take a selection of the results
    $EntityList = $EntityList | Get-Random -Count $DebugSize
}
else
{
    # Sort the list, just so the progression looks better (this is completely optional)
    $EntityList = $EntityList | Sort-Object -Property Caption
}


# We need to build an authenticated Web Session to make the API calls
# if the web session doesn't already exist, we need to build it.
if ( -not ( $WebSession ) )
{
    Write-Host -Object "[Elapsed: $( $sw.Elapsed )] Build the web session"
    # We just need the "WebSession" variable not the results of the call, so we shunt it off to null
    # We are using the native Orion authentication.  If we authenticate a different way, it needs to be changed here.
    Invoke-WebRequest -Uri "http://$( $OrionServer )?AccountID=$( $OrionUsername )&Password=$( $OrionPassword )" -SessionVariable WebSession | Out-Null
}

# Stopwatch for the API Used to determine the time to completion for the progress bars only
$SwApi = New-Object -TypeName System.Diagnostics.Stopwatch
Write-Host -Object "Kicking off the stopwatch"
$SwApi.Start()
$counter = 0
ForEach ( $Entity in $EntityList )
{
    try
    {
        Write-Progress -Activity "Querying alerts" -CurrentOperation "[$( $counter.ToString("0" * ( $EntityList.Count.ToString().Length ) ) )/$( $EntityList.Count )] $( $Entity.Caption ) for $( $Entity.InstanceType )" -PercentComplete ( $counter / $EntityList.Count * 100 ) -SecondsRemaining ( ( $swApi.Elapsed.TotalSeconds / ( $counter + 1 ) ) * ( $EntityList.Count - $counter ) )
        Write-Host -Object "[Elapsed: $( $sw.Elapsed )] [$( $counter + 1)/$( $EntityList.Count )] Querying API for Alerts for $( $Entity.Caption ) for $( $Entity.InstanceType )"

        # Build a JSON formatted request for the API
        $ApiCallJson = @{
            "EntityName"                = $Entity.InstanceType
            "TriggeringObjectEntityUri" = $Entity.Uri
            "CurrentPageIndex"          = 0
            "PageSize"                  = $PageSize
            "OrderByClause"             = ""
            "LimitationIds"             = @()
        } | ConvertTo-Json

        <#
        Important Note:
        Currently this script does not support multiple "pages" of alerts.  If you have more than $PageSize alerts on a specific element, we only pull the first $PageSize.
        This is one of the things to be worked on for the future.
        #>

        Write-Host -Object "[Elapsed: $( $sw.Elapsed )]`tMaking Call to API" -ForegroundColor Cyan
        # Make the call to the API
        $results = Invoke-RestMethod -Uri $GetAlertsUri -WebSession $WebSession -Method POST -Body $ApiCallJson -ContentType "application/json" -ErrorAction SilentlyContinue
        # if we get results, then let's build the details
        if ( $results.TotalRows -gt 0 )
        {

            Write-Host -Object "[Elapsed: $( $sw.Elapsed )]`tFound $( $results.DataTable.Columns.Count ) matching rows" -ForegroundColor DarkYellow

            # Shortcutting $Columns and $Rows for easier reading
            $Fields = $results.DataTable.Columns
            $Values = $results.DataTable.Rows

        
            # For each alert, grab the entity information we already know...
            For ( $i = 0; $i -lt $Values.Count; $i++ )
            {
                Write-Host -Object "[Elapsed: $( $sw.Elapsed )]`tBuiling new PowerShell Object" -ForegroundColor Green
                $AlertObject = New-Object -TypeName PSObject
                $AlertObject | Add-Member -MemberType NoteProperty -Name NodeID        -Value $Entity.NodeID        -Force -Verbose
                $AlertObject | Add-Member -MemberType NoteProperty -Name Caption       -Value $Entity.Caption       -Force -Verbose
                $AlertObject | Add-Member -MemberType NoteProperty -Name IPAddress     -Value $Entity.IPAddress     -Force -Verbose
                $AlertObject | Add-Member -MemberType NoteProperty -Name Vendor        -Value $Entity.Vendor        -Force -Verbose
                $AlertObject | Add-Member -MemberType NoteProperty -Name SubElID       -Value $Entity.SubElID       -Force -Verbose
                $AlertObject | Add-Member -MemberType NoteProperty -Name SubElName     -Value $Entity.SubElName     -Force -Verbose
                $AlertObject | Add-Member -MemberType NoteProperty -Name SubElType     -Value $Entity.SubElType     -Force -Verbose
                $AlertObject | Add-Member -MemberType NoteProperty -Name SubElTypeDesc -Value $Entity.SubElTypeDesc -Force -Verbose
                For ( $j = 0; $j -lt $Fields.Count; $j++ )
                {
                    # ... and add the Alert Information we didn't have before
                    #
                    # This format is used because of custom properties.  An off the shelf system only has 1, but if there are more, then we need the flexibility
                    Write-Host -Object "`tAdding '$( $Fields[$j] )' as a field with a value of '$( $Values[$i][$j] )'" -ForegroundColor Yellow
                    $AlertObject | Add-Member -MemberType NoteProperty -Name ( $Fields[$j] ) -Value ( $Values[$i][$j] ) -Force -Verbose
                }
                $AlertDetails += $AlertObject
            }
        }
        else
        {
            # No results - just put it out to the screen
            Write-Host -Object "No results for $( $Entity.Uri )" -ForegroundColor Red
        }
    }
    catch
    {
        # We encoutered an error of some kind.
        Write-Error -Message "Error received for URI: $( $Entity.Uri )"
    }
    $counter++
}
# Stop the API stopwatch
$SwApi.Stop()
# Stop the progress bar
Write-Progress -Activity "Querying alerts" -Completed

# Stop the script stopwatch and display the total runtime
$sw.Stop()
Write-Host -Object "Total Execution Time: $( $sw.Elapsed )" -ForegroundColor Red

# Output the results stored in $AlertDetails
$AlertDetails
