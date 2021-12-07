$ErrorActionPreference = "Stop"

function Find-DiskMonthlyPrice {
    param (
        [object[]] $SKUPriceSheet,
        [string] $DiskSizeTier
    )

    $diskSkus = $SKUPriceSheet | Where-Object { $_.meterDetails.meterName.Replace(" Disks","") -eq $DiskSizeTier }
    $targetMonthlyPrice = [double]::MaxValue
    if ($diskSkus)
    {
        $targetMonthlyPrice = [double] ($diskSkus | Sort-Object -Property unitPrice | Select-Object -First 1).unitPrice
    }
    return $targetMonthlyPrice
}

# Collect generic and recommendation-specific variables

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$authenticationOption = Get-AutomationVariable -Name "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue # RunAsAccount|ManagedIdentity
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "RunAsAccount"
}

$workspaceId = Get-AutomationVariable -Name  "AzureOptimization_LogAnalyticsWorkspaceId"
$workspaceName = Get-AutomationVariable -Name  "AzureOptimization_LogAnalyticsWorkspaceName"
$workspaceRG = Get-AutomationVariable -Name  "AzureOptimization_LogAnalyticsWorkspaceRG"
$workspaceSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_LogAnalyticsWorkspaceSubId"
$workspaceTenantId = Get-AutomationVariable -Name  "AzureOptimization_LogAnalyticsWorkspaceTenantId"

$storageAccountSink = Get-AutomationVariable -Name  "AzureOptimization_StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkRG"
$storageAccountSinkSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkSubId"
$storageAccountSinkContainer = Get-AutomationVariable -Name  "AzureOptimization_RecommendationsContainer" -ErrorAction SilentlyContinue 
if ([string]::IsNullOrEmpty($storageAccountSinkContainer)) {
    $storageAccountSinkContainer = "recommendationsexports"
}

$deploymentDate = Get-AutomationVariable -Name  "AzureOptimization_DeploymentDate" # yyyy-MM-dd format
$deploymentDate = $deploymentDate.Replace('"', "")

$lognamePrefix = Get-AutomationVariable -Name  "AzureOptimization_LogAnalyticsLogPrefix" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($lognamePrefix))
{
    $lognamePrefix = "AzureOptimization"
}

$sqlserver = Get-AutomationVariable -Name  "AzureOptimization_SQLServerHostname"
$sqlserverCredential = Get-AutomationPSCredential -Name "AzureOptimization_SQLServerCredential"
$SqlUsername = $sqlserverCredential.UserName 
$SqlPass = $sqlserverCredential.GetNetworkCredential().Password 
$sqldatabase = Get-AutomationVariable -Name  "AzureOptimization_SQLServerDatabase" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($sqldatabase))
{
    $sqldatabase = "azureoptimization"
}

# perf thresholds variables
$iopsPercentageThreshold = [int] (Get-AutomationVariable -Name  "AzureOptimization_PerfThresholdDiskIOPSPercentage" -ErrorAction SilentlyContinue)
if (-not($iopsPercentageThreshold -gt 0)) {
    $iopsPercentageThreshold = 5
}
$mbsPercentageThreshold = [int] (Get-AutomationVariable -Name  "AzureOptimization_PerfThresholdDiskMBsPercentage" -ErrorAction SilentlyContinue)
if (-not($mbsPercentageThreshold -gt 0)) {
    $mbsPercentageThreshold = 5
}

$consumptionOffsetDays = [int] (Get-AutomationVariable -Name  "AzureOptimization_ConsumptionOffsetDays")
$consumptionOffsetDaysStart = $consumptionOffsetDays + 1

$perfDaysBackwards = [int] (Get-AutomationVariable -Name  "AzureOptimization_RecommendPerfPeriodInDays" -ErrorAction SilentlyContinue)
if (-not($perfDaysBackwards -gt 0)) {
    $perfDaysBackwards = 7
}

$perfTimeGrain = Get-AutomationVariable -Name "AzureOptimization_RecommendPerfTimeGrain" -ErrorAction SilentlyContinue
if (-not($perfTimeGrain)) {
    $perfTimeGrain = "1h"
}

$referenceRegion = Get-AutomationVariable -Name "AzureOptimization_ReferenceRegion"

$SqlTimeout = 120
$LogAnalyticsIngestControlTable = "LogAnalyticsIngestControl"

# Authenticate against Azure

Write-Output "Logging in to Azure with $authenticationOption..."

switch ($authenticationOption) {
    "RunAsAccount" { 
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
    "ManagedIdentity" { 
        Connect-AzAccount -Identity
        break
    }
    Default {
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
}

Write-Output "Finding tables where recommendations will be generated from..."

$tries = 0
$connectionSuccess = $false
do {
    $tries++
    try {
        $Conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$sqlserver,1433;Database=$sqldatabase;User ID=$SqlUsername;Password=$SqlPass;Trusted_Connection=False;Encrypt=True;Connection Timeout=$SqlTimeout;") 
        $Conn.Open() 
        $Cmd=new-object system.Data.SqlClient.SqlCommand
        $Cmd.Connection = $Conn
        $Cmd.CommandTimeout = $SqlTimeout
        $Cmd.CommandText = "SELECT * FROM [dbo].[$LogAnalyticsIngestControlTable] WHERE CollectedType IN ('ARGManagedDisk','MonitorMetrics','ARGResourceContainers','AzureConsumption')"
    
        $sqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
        $sqlAdapter.SelectCommand = $Cmd
        $controlRows = New-Object System.Data.DataTable
        $sqlAdapter.Fill($controlRows) | Out-Null            
        $connectionSuccess = $true
    }
    catch {
        Write-Output "Failed to contact SQL at try $tries."
        Write-Output $Error[0]
        Start-Sleep -Seconds ($tries * 20)
    }    
} while (-not($connectionSuccess) -and $tries -lt 3)

if (-not($connectionSuccess))
{
    throw "Could not establish connection to SQL."
}

$disksTableName = $lognamePrefix + ($controlRows | Where-Object { $_.CollectedType -eq 'ARGManagedDisk' }).LogAnalyticsSuffix + "_CL"
$metricsTableName = $lognamePrefix + ($controlRows | Where-Object { $_.CollectedType -eq 'MonitorMetrics' }).LogAnalyticsSuffix + "_CL"
$subscriptionsTableName = $lognamePrefix + ($controlRows | Where-Object { $_.CollectedType -eq 'ARGResourceContainers' }).LogAnalyticsSuffix + "_CL"
$consumptionTableName = $lognamePrefix + ($controlRows | Where-Object { $_.CollectedType -eq 'AzureConsumption' }).LogAnalyticsSuffix + "_CL"

Write-Output "Will run query against tables $disksTableName, $metricsTableName, $subscriptionsTableName and $consumptionTableName"

$Conn.Close()    
$Conn.Dispose()            

$recommendationSearchTimeSpan = 30 + $consumptionOffsetDaysStart

# Grab a context reference to the Storage Account where the recommendations file will be stored

Select-AzSubscription -SubscriptionId $storageAccountSinkSubscriptionId
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink

if ($workspaceSubscriptionId -ne $storageAccountSinkSubscriptionId)
{
    Select-AzSubscription -SubscriptionId $workspaceSubscriptionId
}

Write-Output "Getting Disks SKUs for the $referenceRegion region..."

$skus = Get-AzComputeResourceSku | Where-Object { $_.ResourceType -eq "disks" -and $_.LocationInfo.Location -eq $referenceRegion }

Write-Output "Getting the current Pricesheet..."

if ($cloudEnvironment -eq "AzureCloud")
{
    $pricesheetRegion = "EU West"
}

try 
{
    $pricesheet = $null
    $pricesheetEntries = @()
    $subscription = $workspaceSubscriptionId
    $PriceSheetApiPath = "/subscriptions/$subscription/providers/Microsoft.Consumption/pricesheets/default?api-version=2019-10-01&%24expand=properties%2FmeterDetails"

    do
    {
        if (-not([string]::IsNullOrEmpty($pricesheet.properties.nextLink)))
        {
            $PriceSheetApiPath = $pricesheet.properties.nextLink.Substring($pricesheet.properties.nextLink.IndexOf("/subscriptions/"))
        }
        $tries = 0
        $requestSuccess = $false
        do 
        {        
            try {
                $tries++
                $pricesheet = (Invoke-AzRestMethod -Path $PriceSheetApiPath -Method GET).Content | ConvertFrom-Json

                if ($pricesheet.error)
                {
                    throw "Cost Management not available ($($pricesheet.error.message))"
                }    

                $requestSuccess = $true
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                Write-Warning "Error getting consumption data: $ErrorMessage. $tries of 3 tries. Waiting 30 seconds..."
                Start-Sleep -s 30   
            }
        } while ( -not($requestSuccess) -and $tries -lt 3 )

        if ($pricesheet.error)
        {
            throw "Cost Management not available"
        }

        $pricesheetEntries += $pricesheet.properties.pricesheets | Where-Object { $_.meterDetails.meterLocation -eq $pricesheetRegion -and `
            $_.meterDetails.meterCategory -eq "Storage" -and $_.meterDetails.meterSubCategory -like "* Managed Disks" -and $_.meterDetails.meterName -like "*Disks" }

    }
    while ($requestSuccess -and -not([string]::IsNullOrEmpty($pricesheet.properties.nextLink)))
}
catch
{
    Write-Output "Consumption pricesheet not available, will estimate savings based in price difference ratio..."
    $pricesheet = $null
}

$skuPricesFound = @{}

Write-Output "Looking for underutilized Disks, with less than $iopsPercentageThreshold% IOPS and $mbsPercentageThreshold% MB/s usage..."

$baseQuery = @"
    let billingInterval = 30d;
    let perfInterval = $($perfDaysBackwards)d; 
    let etime = todatetime(toscalar($consumptionTableName | summarize max(UsageDate_t))); 
    let stime = etime-billingInterval; 

    let BilledDisks = $consumptionTableName
    | where UsageDate_t between (stime..etime) and InstanceId_s contains '/disks/' and MeterCategory_s == 'Storage' and MeterSubCategory_s has 'Premium' and MeterName_s has 'Disks'
    | extend DiskConsumedQuantity = todouble(Quantity_s)
    | extend DiskPrice = todouble(UnitPrice_s)
    | extend FinalCost = DiskPrice * DiskConsumedQuantity
    | extend ResourceId = InstanceId_s
    | summarize Last30DaysCost = sum(FinalCost), Last30DaysQuantity = sum(DiskConsumedQuantity) by ResourceId;

    $metricsTableName
    | where MetricNames_s == 'Composite Disk Read Operations/sec,Composite Disk Write Operations/sec' and TimeGenerated > ago(perfInterval) and isnotempty(MetricValue_s)
    | summarize MaxIOPSMetric = max(todouble(MetricValue_s)) by ResourceId
    | join kind=inner ( 
        $disksTableName
        | where TimeGenerated > ago(1d) and DiskState_s != 'Unattached' and SKU_s startswith 'Premium'
        | project ResourceId=InstanceId_s, DiskName_s, ResourceGroup = ResourceGroupName_s, SubscriptionId = SubscriptionGuid_g, Cloud_s, TenantGuid_g, Tags_s, MaxIOPSDisk=toint(DiskIOPS_s), DiskSizeGB_s, SKU_s, DiskTier_s, DiskType_s
    ) on ResourceId
    | project-away ResourceId1
    | extend IOPSPercentage = MaxIOPSMetric/MaxIOPSDisk*100
    | where IOPSPercentage < $iopsPercentageThreshold
    | join kind=inner (
        $metricsTableName
        | where MetricNames_s == 'Composite Disk Read Bytes/sec,Composite Disk Write Bytes/sec' and TimeGenerated > ago(perfInterval) and isnotempty(MetricValue_s)
        | summarize MaxMBsMetric = max(todouble(MetricValue_s)/1024/1024) by ResourceId
        | join kind=inner ( 
            $disksTableName
            | where TimeGenerated > ago(1d) and DiskState_s != 'Unattached' and SKU_s startswith 'Premium'
            | project ResourceId=InstanceId_s, DiskName_s, ResourceGroup = ResourceGroupName_s, SubscriptionId = SubscriptionGuid_g, Cloud_s, TenantGuid_g, Tags_s, MaxMBsDisk=toint(DiskThroughput_s), DiskSizeGB_s, SKU_s, DiskTier_s, DiskType_s
        ) on ResourceId
        | project-away ResourceId1
        | extend MBsPercentage = MaxMBsMetric/MaxMBsDisk*100
        | where MBsPercentage < $mbsPercentageThreshold
    ) on ResourceId
    | join kind=inner ( BilledDisks ) on ResourceId
"@

try
{
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $baseQuery -Timespan (New-TimeSpan -Days $recommendationSearchTimeSpan) -Wait 600 -IncludeStatistics
    if ($queryResults)
    {
        $results = [System.Linq.Enumerable]::ToArray($queryResults.Results)        
    }
}
catch
{
    Write-Warning -Message "Query failed. Debug the following query in the AOE Log Analytics workspace: $baseQuery"    
}

Write-Output "Query finished with $($results.Count) results."

Write-Output "Query statistics: $($queryResults.Statistics.query)"

# Build the recommendations objects

$recommendations = @()
$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")

foreach ($result in $results)
{
<#

$diskSkus = Get-AzComputeResourceSku -Location "westeurope" | Where-Object { $_.ResourceType -eq "disks" -and $_.Name -eq 'Standard_LRS' } // O name tem de ser igual ao SKU_s!

$diskSkus[0].Capabilities.MaxSizeGiB (4)
$diskSkus[0].Capabilities.MaxIOps (120)
$diskSkus[0].Capabilities.MaxBandwidthMBps (25)
$diskSkus[0].Capabilities.MaxBurstIops (3500)
$diskSkus[0].Capabilities.MaxBurstBandwidthMBps (170)

($diskSkus[0].Capabilities | Where-Object { $_.Name -eq 'MaxIOps' }).Value

$diskSkus[0].Size (P1)
#>

    $targetSku = $null

    if ($null -eq $skuPricesFound[$result.DiskTier_s])
    {
        $skuPricesFound[$result.DiskTier_s] = Find-DiskMonthlyPrice -DiskSizeTier $result.DiskTier_s -SKUPriceSheet $pricesheetEntries
    }

    $targetSkuPerfTier = $result.SKU_s.Replace("Premium", "StandardSSD")
    $targetSkuCandidates = @()

    foreach ($sku in $skus)
    {
        $targetSkuCandidate = $null

        $skuMinSizeGB = [int] ($sku.Capabilities | Where-Object { $_.Name -eq 'MinSizeGiB' }).Value
        $skuMaxSizeGB = [int] ($sku.Capabilities | Where-Object { $_.Name -eq 'MaxSizeGiB' }).Value
        $skuMaxIOps = [int] ($sku.Capabilities | Where-Object { $_.Name -eq 'MaxIOps' }).Value
        $skuMaxBandwidthMBps = [int] ($sku.Capabilities | Where-Object { $_.Name -eq 'MaxBandwidthMBps' }).Value

        if ($sku.Name -eq $targetSkuPerfTier -and $skuMinSizeGB -le [int]$result.DiskSizeGB_s -and $skuMaxSizeGB -ge [int]$result.DiskSizeGB_s `
                -and [double]$skuMaxIOps -ge [double]$result.MaxIOPSMetric -and [double]$skuMaxBandwidthMBps -ge [double]$result.MaxMBsMetric)
        {
            if ($null -eq $skuPricesFound[$sku.Size])
            {
                $skuPricesFound[$sku.Size] = Find-DiskMonthlyPrice -DiskSizeTier $sku.Size -SKUPriceSheet $pricesheetEntries
            }

            if ($skuPricesFound[$sku.Size] -lt [double]::MaxValue -and $skuPricesFound[$sku.Size] -lt $skuPricesFound[$result.DiskTier_s])
            {
                $targetSkuCandidate = New-Object PSObject -Property @{
                    Name = $sku.Size
                    MonthlyPrice = $skuPricesFound[$sku.Size]
                    MaxSizeGB = $skuMaxSizeGB
                    MaxIOPS = $skuMaxIOps
                    MaxMBps = $skuMaxBandwidthMBps
                }

                $targetSkuCandidates += $targetSkuCandidate    
            }
        }
    }

    $targetSku = $targetSkuCandidates | Sort-Object -Property MonthlyPrice | Select-Object -First 1

    if ($null -ne $targetSku)
    {
        $queryInstanceId = $result.InstanceId_s
        $queryText = @"
        let billingInterval = 30d; 
        let armId = `'$queryInstanceId`';
        let gInt = $perfTimeGrain;
        let MemoryPerf = $metricsTableName 
        | where TimeGenerated > ago(billingInterval)
        | extend CollectedDate = todatetime(strcat(format_datetime(TimeGenerated, 'yyyy-MM-dd'),'T',format_datetime(TimeGenerated, 'HH'),':00:00Z'))
        | where ResourceId == armId
        | where MetricNames_s == 'Available Memory Bytes' and AggregationType_s == 'Minimum'
        | extend MemoryAvailableMBs = todouble(MetricValue_s)/1024/1024
        | project CollectedDate, MemoryAvailableMBs, InstanceId_s=ResourceId
        | join kind=inner (
            $vmssTableName 
            | where TimeGenerated > ago(1d)
            | distinct InstanceId_s, MemoryMB_s
        ) on InstanceId_s
        | extend MemoryPercentage = todouble(toint(MemoryMB_s) - toint(MemoryAvailableMBs)) / todouble(MemoryMB_s) * 100 
        | summarize percentile(MemoryPercentage, $memoryPercentile) by bin(CollectedDate, gInt);
        let ProcessorPerf = $metricsTableName 
        | where TimeGenerated > ago(billingInterval) 
        | extend CollectedDate = todatetime(strcat(format_datetime(TimeGenerated, 'yyyy-MM-dd'),'T',format_datetime(TimeGenerated, 'HH'),':00:00Z'))
        | where ResourceId == armId
        | where MetricNames_s == 'Percentage CPU' and AggregationType_s == 'Maximum'
        | extend ProcessorPercentage = todouble(MetricValue_s)
        | summarize percentile(ProcessorPercentage, $cpuPercentile) by bin(CollectedDate, gInt);
        MemoryPerf
        | join kind=inner (ProcessorPerf) on CollectedDate
        | render timechart
"@

        switch ($cloudEnvironment)
        {
            "AzureCloud" { $azureTld = "com" }
            "AzureChinaCloud" { $azureTld = "cn" }
            "AzureUSGovernment" { $azureTld = "us" }
            default { $azureTld = "com" }
        }

        $encodedQuery = [System.Uri]::EscapeDataString($queryText)
        $detailsQueryStart = $datetime.AddDays(-30).ToString("yyyy-MM-dd")
        $detailsQueryEnd = $datetime.AddDays(8).ToString("yyyy-MM-dd")
        $detailsURL = "https://portal.azure.$azureTld#@$workspaceTenantId/blade/Microsoft_Azure_Monitoring_Logs/LogsBlade/resourceId/%2Fsubscriptions%2F$workspaceSubscriptionId%2Fresourcegroups%2F$workspaceRG%2Fproviders%2Fmicrosoft.operationalinsights%2Fworkspaces%2F$workspaceName/source/LogsBlade.AnalyticsShareLinkToQuery/query/$encodedQuery/timespan/$($detailsQueryStart)T00%3A00%3A00.000Z%2F$($detailsQueryEnd)T00%3A00%3A00.000Z"
    
        $additionalInfoDictionary = @{}
    
        $additionalInfoDictionary["SupportsDataDisksCount"] = "true"
        $additionalInfoDictionary["SupportsNICCount"] = "true"
        $additionalInfoDictionary["BelowCPUThreshold"] = "true"
        $additionalInfoDictionary["BelowMemoryThreshold"] = "true"
        $additionalInfoDictionary["currentSku"] = "$($result.VMSSSize_s)"
        $additionalInfoDictionary["targetSku"] = "$($targetSku.Name)"
        $additionalInfoDictionary["DataDiskCount"] = "$($result.DataDiskCount_s)"
        $additionalInfoDictionary["NicCount"] = "$($result.NicCount_s)"
        $additionalInfoDictionary["MetricCPUPercentage"] = "$($result.PCPUPercentage)"
        $additionalInfoDictionary["MetricMemoryPercentage"] = "$($result.PMemoryPercentage)"
    
        $fitScore = 4 # needs disk IOPS and throughput analysis to improve score
        
        $fitScore = [Math]::max(0.0, $fitScore)

        $savingCoefficient = [double] $currentSkuvCPUs / [double] $targetSku.vCPUsAvailable

        if ($targetSku -and $null -eq $skuPricesFound[$targetSku.Name])
        {
            $skuPricesFound[$targetSku.Name] = Find-SkuHourlyPrice -SKUName $targetSku.Name -SKUPriceSheet $pricesheetEntries
        }

        $targetSkuSavingsMonthly = $result.Last30DaysCost - ($result.Last30DaysCost / $savingCoefficient)

        if ($targetSku -and $skuPricesFound[$targetSku.Name] -lt [double]::MaxValue)
        {
            $targetSkuPrice = $skuPricesFound[$targetSku.Name]    

            if ($null -eq $skuPricesFound[$currentSku.Name])
            {
                $skuPricesFound[$currentSku.Name] = Find-SkuHourlyPrice -SKUName $currentSku.Name -SKUPriceSheet $pricesheetEntries
            }

            if ($skuPricesFound[$currentSku.Name] -lt [double]::MaxValue)
            {
                $currentSkuPrice = $skuPricesFound[$currentSku.Name]    
                $targetSkuSavingsMonthly = ($currentSkuPrice * [double] $result.Last30DaysQuantity) - ($targetSkuPrice * [double] $result.Last30DaysQuantity)    
            }
            else
            {
                $targetSkuSavingsMonthly = $result.Last30DaysCost - ($targetSkuPrice * [double] $result.Last30DaysQuantity)    
            }
        }

        $tags = @{}

        if (-not([string]::IsNullOrEmpty($result.Tags_s)))
        {
            $tagPairs = $result.Tags_s.Substring(2, $result.Tags_s.Length - 3).Split(';')
            foreach ($tagPairString in $tagPairs)
            {
                $tagPair = $tagPairString.Split('=')
                if (-not([string]::IsNullOrEmpty($tagPair[0])) -and -not([string]::IsNullOrEmpty($tagPair[1])))
                {
                    $tagName = $tagPair[0].Trim()
                    $tagValue = $tagPair[1].Trim()
                    $tags[$tagName] = $tagValue    
                }
            }
        }            
    
        if ($targetSkuSavingsMonthly -eq [double]::PositiveInfinity)
        {
            $targetSkuSavingsMonthly = [double] $result.Last30DaysCost / 2
        }

        $additionalInfoDictionary["savingsAmount"] = [double] $targetSkuSavingsMonthly     
        $additionalInfoDictionary["CostsAmount"] = [double] $result.Last30DaysCost 
    
        $recommendation = New-Object PSObject -Property @{
            Timestamp                   = $timestamp
            Cloud                       = $result.Cloud_s
            Category                    = "Cost"
            ImpactedArea                = "Microsoft.Compute/virtualMachineScaleSets"
            Impact                      = "High"
            RecommendationType          = "Saving"
            RecommendationSubType       = "UnderusedVMSS"
            RecommendationSubTypeId     = "a4955cc9-533d-46a2-8625-5c4ebd1c30d5"
            RecommendationDescription   = "VM Scale Set has been underutilized"
            RecommendationAction        = "Resize VM Scale Set to lower SKU or scale it in"
            InstanceId                  = $result.InstanceId_s
            InstanceName                = $result.VMSSName
            AdditionalInfo              = $additionalInfoDictionary
            ResourceGroup               = $result.ResourceGroup
            SubscriptionGuid            = $result.SubscriptionId
            SubscriptionName            = $result.SubscriptionName
            TenantGuid                  = $result.TenantGuid_g
            FitScore                    = $fitScore
            Tags                        = $tags
            DetailsURL                  = $detailsURL
        }
    
        $recommendations += $recommendation        
    }
}

# Export the recommendations as JSON to blob storage

$fileDate = $datetime.ToString("yyyy-MM-dd")
$jsonExportPath = "disks-underutilized-$fileDate.json"
$recommendations | ConvertTo-Json | Out-File $jsonExportPath

$jsonBlobName = $jsonExportPath
$jsonProperties = @{"ContentType" = "application/json"};
Set-AzStorageBlobContent -File $jsonExportPath -Container $storageAccountSinkContainer -Properties $jsonProperties -Blob $jsonBlobName -Context $sa.Context -Force
