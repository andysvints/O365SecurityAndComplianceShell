﻿<#
.Synopsis Override Get-PSImplicitRemotingSession function for reconnection
#>
function global:UpdateImplicitRemotingHandler()
{
    $modules = Get-Module tmp_*

    foreach ($module in $modules)
    {
        [bool]$moduleProcessed = $false
        [string] $moduleUrl = $module.Description
        [int] $queryStringIndex = $moduleUrl.IndexOf("?")
        $O365SecurityAndComplianceShellModule=Get-Module O365SecurityAndComplianceShell
        $ModuleBase=$O365SecurityAndComplianceShellModule.ModuleBase
        Import-Module "$ModuleBase\Microsoft.Exchange.Management.ExoPowershellModule.dll" -Global
        Import-Module "$ModuleBase\Microsoft.IdentityModel.Clients.ActiveDirectory.dll" -Global
        Import-Module "$ModuleBase\Microsoft.IdentityModel.Clients.ActiveDirectory.WindowsForms.dll" -Global
        
        if ($queryStringIndex -gt 0)
        {
            $moduleUrl = $moduleUrl.SubString(0,$queryStringIndex)
        }

        if ($moduleUrl.EndsWith("/PowerShell-LiveId/", [StringComparison]::OrdinalIgnoreCase) -or $moduleUrl.EndsWith("/PowerShell", [StringComparison]::OrdinalIgnoreCase))
        {
            & $module { ${function:Get-PSImplicitRemotingSession} = `
            {
                param(
                    [Parameter(Mandatory = $true, Position = 0)]
                    [string]
                    $commandName
                )

                if (($script:PSSession -eq $null) -or ($script:PSSession.Runspace.RunspaceStateInfo.State -ne 'Opened'))
                {
                    Set-PSImplicitRemotingSession `
                        (& $script:GetPSSession `
                            -InstanceId $script:PSSession.InstanceId.Guid `
                            -ErrorAction SilentlyContinue )
                }
                if (($script:PSSession -ne $null) -and ($script:PSSession.Runspace.RunspaceStateInfo.State -eq 'Disconnected'))
                {
                    # If we are handed a disconnected session, try re-connecting it before creating a new session.
                    Set-PSImplicitRemotingSession `
                        (& $script:ConnectPSSession `
                            -Session $script:PSSession `
                            -ErrorAction SilentlyContinue)
                }
                if (($script:PSSession -eq $null) -or ($script:PSSession.Runspace.RunspaceStateInfo.State -ne 'Opened'))
                {
                    Write-PSImplicitRemotingMessage ('Creating a new Remote PowerShell session using MFA for implicit remoting of "{0}" command ...' -f $commandName)
                    $session = New-ExoPSSession -UserPrincipalName $global:UserPrincipalName -ConnectionUri $global:ConnectionUri -AzureADAuthorizationEndpointUri $global:AzureADAuthorizationEndpointUri -PSSessionOption $global:PSSessionOption -Credential $global:Credential

                    if ($session -ne $null)
                    {
                        Set-PSImplicitRemotingSession -CreatedByModule $true -PSSession $session
                    }

                    RemoveBrokenOrClosedPSSession
                }
                if (($script:PSSession -eq $null) -or ($script:PSSession.Runspace.RunspaceStateInfo.State -ne 'Opened'))
                {
                    throw 'No session has been associated with this implicit remoting module'
                }

                return [Management.Automation.Runspaces.PSSession]$script:PSSession
            }}
        }
    }
}

<#
.Synopsis Remove broken and closed sessions
#>
function  global:RemoveBrokenOrClosedPSSession()
{
    $psBroken = Get-PSSession | where-object {$_.State -like "*Broken*"}
    $psClosed = Get-PSSession | where-object {$_.State -like "*Closed*"}

    if ($psBroken.count -gt 0)
    {
        for ($index = 0; $index -lt $psBroken.count; $index++)
        {
            Remove-PSSession -session $psBroken[$index]
        }
    }

    if ($psClosed.count -gt 0)
    {
        for ($index = 0; $index -lt $psClosed.count; $index++)
        {
            Remove-PSSession -session $psClosed[$index]
        }
    }
}

<#
.Synopsis
   Connect to Office365 Security and Compliance Center Powershell using Proxy settings or directly.
.DESCRIPTION
   Used to Connect to Office365 Security and Compliance Center. 
   It checks if you computer is using any proxy settings and import them from IE if needed.
.EXAMPLE
   PS C:\>Connect-O365SecurityAndComplianceShell 
   Connecting to Office365 Security and Compliance Shell and let the cmdlet to figure out if any Proxy Settings are in place.
.EXAMPLE 
   Connect-O365SecurityAndComplianceShell -SkipProxyCheck
   Connecting to Office365 Security and Compliance Shell directly
.EXAMPLE
    Connect-O365SecurityAndComplianceShell -RenameConsoleWindow
    Connecting to Office365 Security and Compliance Shell and renaming console window to Office365 Security and Compliance Shell: <UserDomain>.
#>
function Connect-O365SecurityAndComplianceShell
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    [Alias('cscs','Connect-O365SCShell')]
    Param
    (
        # Credentials Used to Connect to Exchange Online Shell
        [System.Management.Automation.PSCredential]$Credential= $null,
        
        #Used to Skip Proxy Settings Check
        [Alias('NoProxy')]
        [Switch]$SkipProxyCheck,

        #Used to rename console window to '0365 Security and Compliance Center: <>'
        [Alias()]
        [switch]$RenameConsoleWindow
    )

    Begin
    {
        $ConnectionUri="https://ps.compliance.protection.outlook.com/powershell-liveid/"
        $AzureADAuthorizationEndpointUri="https://login.windows.net/common"
        $global:ConnectionUri = $ConnectionUri;
        $global:AzureADAuthorizationEndpointUri = $AzureADAuthorizationEndpointUri;
        $global:UserPrincipalName = $UserPrincipalName;
        
        $global:Credential = $Credential;
        $ProxyUsed=$false
        if(!$SkipProxyCheck){
            
            Write-Verbose "Checking Proxy Settings on computer it might take some time. Please be patient"
            Write-Verbose "Proxy Setings Check 1 of 2: Registry Check"
            Write-Verbose "Reading Proxy Settings from Registry"
            $Proxy = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            if($Proxy.ProxyEnable){
                Write-Verbose "Proxy Settings have been detected"
                $ProxyUsed=$true
                break
            }else{
                Write-Verbose "No Proxy Settings detected"
                $ProxyUsed=$false
            }

            Write-Verbose "Proxy Setings Check 2 of 2: Transparent Proxy Check"
            Write-Verbose "If you have a transparent proxy, your computer will not provide any info about it"
            Write-Verbose "Trying to connect to outlook.office365.com via port 443 directly"
            $TCPobj=New-Object System.Net.Sockets.TCPClient
            $Connect=$TCPobj.BeginConnect("outlook.office365.com",443,$null,$null)
            $wait=$Connect.AsyncWaitHandle.WaitOne(2000,$false)
            if(!$wait){
                Write-Verbose "Connection could not be established : TimeOut has been reached"
                Write-Verbose "Most likely your computer is using Transparent Proxy"
                $ProxyUsed=$true
            }else{
                $TCPobj.EndConnect($Connect) | out-Null 
                Write-Verbose "Connection has been established successfully"
                Write-Verbose "No Transparent Proxy settings detected"
                $ProxyUsed=$false
            }
            
        }else{
            Write-Verbose "Skipping Proxy Settings Check and Connecting to outlook.office365.com directly"
        }
    
    }
    Process
    {
        if ($pscmdlet.ShouldProcess( "Office365 Security and Compliance Shell")){
            if($ProxyUsed){
                Write-Verbose "Proxy Server is used: Importing Proxy Settings from IE"
                $proxySettings = New-PSSessionOption -ProxyAccessType IEConfig -ProxyAuthentication basic
                $global:PSSessionOption = $proxySettings;
                Write-Verbose "Creating Session Object using $($Credential.UserName) credentials"
                $PSSession=New-ExoPSSession -UserPrincipalName $($Credential.UserName) -ConnectionUri $ConnectionUri -AzureADAuthorizationEndpointUri $AzureADAuthorizationEndpointUri -PSSessionOption $proxySettings -Credential $Credential
            }else{
                Write-Verbose "No Proxy Detected: Connecting to Office365 Security and Compliance Shell Directly"
                Write-Verbose "Creating Session Object using $($Credential.UserName) credentials"
                $PSSession=New-ExoPSSession -UserPrincipalName $($Credential.UserName) -ConnectionUri $ConnectionUri -AzureADAuthorizationEndpointUri $AzureADAuthorizationEndpointUri  -Credential $Credential
            }

            if($ExchangeOnlineSessionObjectError){
                Write-Verbose "Failed to create a Session Object"
                Write-Verbose "Please double check your credentials and try again"
            }else{
                Write-Verbose "Session Object has been created successfully"
                Write-Verbose "Importing Created Session"
                Import-Module (Import-PSSession $PSSession -AllowClobber -ErrorAction SilentlyContinue) -Global -ErrorAction Stop
                Write-Verbose "Session has been imported successfully"
                Write-Verbose "Now you are connected to O365SecurityAndComplianceShell"
                $Domain=$((Get-AdminAuditLogConfig -ErrorAction SilentlyContinue | select -ExpandProperty id).split('/')[-3]) 
                UpdateImplicitRemotingHandler
            }
       }
    }
    End
    {
        
        If($RenameConsoleWindow){
            Write-Verbose "Renaming Console Window to Office365 Security and Compliance Shell: $Domain"
            $HOst.UI.RawUI.WindowTitle="Office365 Security and Compliance Shell: $Domain"
        }
    }
}

<#
.Synopsis
   Disconnect the Office365 Security and Compliance Session.
.DESCRIPTION
   Gets all the Sessions with Microsoft.Exchange Configuration established to outlook.office365.com and removes them. 
.EXAMPLE
    Disconnect-ExchangeOnlineShell
#>
function Disconnect-O365SecurityAndComplianceShell
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    [Alias('dscs','Kill-O365SecurityAndComplianceShellSession','Kill-O365SCShellSession','Disconnect-O365SCShell')]
    Param
    (
    )

    Begin
    {
    }
    Process
    {
        if ($pscmdlet.ShouldProcess( "Office365 Security and Compliance Powershell Sessions")){
            Get-PSSession | Where {$_.ComputerName -like "*.ps.compliance.protection.outlook.com" -and $_.ConfigurationName -eq "Microsoft.Exchange"} | Remove-PSSession
        }
        
    }
    End
    {
        if($Host.UI.RawUI.WindowTitle -like "*Office365 Security and Compliance Shell*"){
            $Host.UI.RawUI.WindowTitle="Windows PowerShell"
        }
    }
}

