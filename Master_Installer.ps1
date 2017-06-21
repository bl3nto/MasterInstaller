param
(
	## force parameter koji override-a provjeru verzija (korisno za reinstall)  -f = force
	[switch]$f,
	## condition parametar koji override-a provjeru conditiona iz XML file-a    -c = conditionless
	[switch]$c,
	## switch koji override-a provjeru da li je već pokrenuta instanca skripte  -m = mandatory
	[switch]$m,
	## switch koji override-a provjeru restarta nakon skipte i force-a ga       -r = restart
	[switch]$r
)

## lokacija LOG datoteke u koju skripta zapisuje podatke i vrijeme čuvanja tih podataka (u danima)
$errorLogger = "C:\Temp\Master_Installer.log"
$logsSpanDays = 180
## lokacija OCS agenta ako je isti instaliran, ako nije, ostaviti prazan string ""
$ocsExecutable = "C:\Program Files (x86)\OCS Inventory Agent\OCSInventory.exe"
## skripta radi retry instalacije 30 puta po 2 sec (tj. čeka 2 minute da prethodna skripta završi)
$waitPeriod = 60
## trenutno UNIX type vrijeme (broj sekunda od 1.1.1970)
$currentUNIXTime = [System.Math]::Round([double]::Parse((Get-Date -UFormat %s)))
## globalna varijabla koje dopušta reboot (ukoliko je instalacija obavljena)
$rebootAllowed = $false
## globalna varijabla koja označava da li je trenutna skripta postavila reboot flag u registry
$rebootFlag = $false

## funkcija koja sprječava računalo da ode u sleep mode sve dok se skripta ne izvrši do kraja
function SleepManager ([bool]$value)
{
	$systemDLL = @' 
	[DllImport("kernel32.dll", CharSet = CharSet.Auto,SetLastError = true)]
	public static extern void SetThreadExecutionState(uint esFlags);
'@

	$ES_CONTINUOUS = [uint32]"0x80000000"
	$ES_SYSTEM_REQUIRED = [uint32]"0x00000001"
	
	if (!$functionCall)
	{
		$functionCall = Add-Type -MemberDefinition $systemDLL -Name System -Namespace Win32 -PassThru -ErrorAction SilentlyContinue
	}	
	
	if($value)
	{
		$functionCall::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
	}
	else
	{
		$functionCall::SetThreadExecutionState($ES_CONTINUOUS)
	}
}

## funkcija koja provjerava da li je OS 64 ili 32 bita i mijenja Program Files putanju po potrebi
function SystemBitness ([string]$value)
{
	if (([System.IntPtr]::Size -eq 4) -And ($value -like "*Program Files (x86)*"))
	{
		$output = $value.Replace("Program Files (x86)", "Program Files")
	}
	else
	{
		$output = $value
	}
	return $output
}

## funkcija koja poziva eksternu skriptu definiranu u XML datoteci
function CustomScript
{
	$cleanScript = -1
	Write-Host "    $(Get-Date -format 'HH:mm:ss') - running script -> $($XML.Application.CustomScript.Path)"
	try
	{
		if ([string]::IsNullOrEmpty($XML.Application.CustomScript.Params))
		{
			$scriptPath = SystemBitness $XML.Application.CustomScript.Path
			Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Custom Script - $($XML.Application.Name)] -- script started: '$scriptPath'"
			$process = Start-Process -FilePath $scriptPath -Verb RunAs -PassThru -WindowStyle Hidden
		}
		else
		{
			$scriptPath = SystemBitness $XML.Application.CustomScript.Path
			$scriptParams = SystemBitness $XML.Application.CustomScript.Params
			Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Custom Script - $($XML.Application.Name)] -- script started: '$scriptPath' with parameters: $scriptParams"
			$process = Start-Process -FilePath $scriptPath -ArgumentList $scriptParams -Verb RunAs -PassThru -WindowStyle Hidden
		}
		
		$handle = $process.Handle
		$process.WaitForExit()
		$cleanScript = $process.ExitCode
		Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Custom Script - $($XML.Application.Name)] -- script finished: $($process.ExitCode)"
		$ocsInitiate = $true
	}
	catch
	{
		#ispis greške na ekranu
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - error running script -> $($XML.Application.CustomScript.Path)`r`n    -- Error - $($_.Exception.Message)"
		$cleanScript = -1
		Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Custom Script - $($XML.Application.Name)] -- $($_.Exception.Message)"
	}
	return $cleanScript
}

## funkcija koja uklanja sve datoteke/direktorije/registry ključeve navedene u XML datoteci
function RemoveFile
{
	foreach ($rawItem in $XML.Application.Remove.Path)
	{
		$item = SystemBitness $rawItem
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - removing -> $item"

		try
		{
			if(Test-Path $item -pathType leaf)
			{
				Remove-Item -path $item -force
			}
			elseif(Test-Path $item -pathType container)
			{
				if ($item.ToString().Substring($item.Length - 1,1) -eq "\")
				{
					$folder = $item.ToString().Substring(0, $item.Length - 1)
					
					Get-ChildItem -path $folder -recurse | Remove-Item -force -recurse
					Remove-Item -path $folder -force -recurse
				}
				else
				{
					Get-ChildItem -Path $item -Recurse | Remove-Item -force -recurse
					Remove-Item -path $item -force -recurse
				}
			}
			else
			{
				Write-Host "    $(Get-Date -format 'HH:mm:ss') - file does not exist -> $item"
			}
		}
		catch
		{
			#ispis greške na ekranu
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - error removing file -> $item`r`n    -- Error - $($_.Exception.Message)"
			Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Remove File - $($XML.Application.Name)] -- $($_.Exception.Message)"
		}
	}
}

## funkcija koja kopira sve datoteke/direktorije navedene u XML datoteci
function CopyFile
{
	foreach ($item in $XML.Application.Copy.FilePair)
	{
		$itemSrc = SystemBitness $item.Src
		$itemDest = SystemBitness $item.Dest
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - copying -> '$itemSrc' -> '$itemDest'"
		
		try
		{
			if(Test-Path $itemSrc -pathType leaf)
			{
				Copy-Item $itemSrc $itemDest -force
			}
			else
			{
				if ($itemDest.ToString().Substring($itemDest.Length - 1,1) -ne "\")
				{
					$itemDest = "$itemDest\"
				}
				
				if ($itemSrc.ToString().Substring($itemSrc.Length - 1,1) -eq "\")
				{
					Copy-Item "$itemSrc*" -destination $itemDest -recurse -force
				}
				else
				{
					Copy-Item "$itemSrc\*" -destination $itemDest -recurse -force
				}
			}
		}
		catch
		{
			#ispis greške na ekranu
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - error copying file -> $itemSrc`r`n    -- Error - $($_.Exception.Message)"
			Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Copy File - $($XML.Application.Name)] -- $($_.Exception.Message)"
		}
	} 	
}

## funkcija koja poziva uninstaller prije nego krene instalacija prema parametrima u XML datoteci
function UninstallApp
{
	$cleanUninstall = -1
	foreach ($item in $XML.Application.Uninstall.Uninstaller)
	{
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - starting uninstall -> $($item.Path) $($item.Params)"
		try
		{
			if ([string]::IsNullOrEmpty($item.Params))
			{
				$uninstallPath = SystemBitness $item.Path
				Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Uninstall App - $($XML.Application.Name)] -- unistall started: $uninstallPath"
				$process = Start-Process -FilePath $uninstallPath -Verb RunAs -PassThru
			}
			else
			{
				$uninstallPath = SystemBitness $item.Path
				$uninstallParams = SystemBitness $item.Params
				Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Uninstall App - $($XML.Application.Name)] -- unistall started: $uninstallPath with parameters $uninstallParams"
				$process = Start-Process -FilePath $uninstallPath -ArgumentList $uninstallParams -Verb RunAs -PassThru
			}
			
			$handle = $process.Handle
			$process.WaitForExit()
			$cleanUninstall = $process.ExitCode
			Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Uninstall App - $($XML.Application.Name)] -- unistall finished: $($process.ExitCode)"
			$ocsInitiate = $true
		}
		catch
		{
			#ispis greške na ekranu
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - error occured during uninstall.`r`n    -- Error - $($_.Exception.Message)" 
			$cleanUninstall = -1
			Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Uninstall App - $($XML.Application.Name)] -- $($_.Exception.Message)"
		}
	}
	return $cleanUninstall
}

## funkcija koja poziva glavni installer prema parametrima u XML datoteci
function InstallApp
{
	$cleanInstall = $true
	foreach ($item in $XML.Application.Install.Installer)
	{
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - starting install -> $($item.Path) $($item.Params)"

		try
		{
			if ([string]::IsNullOrEmpty($item.Params))
			{
				$installPath = SystemBitness $item.Path
				Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Install App - $($XML.Application.Name)] -- install started: $installPath"
				$process = Start-Process -FilePath $installPath -Verb RunAs -PassThru
				
			}
			else
			{
				$installPath = SystemBitness $item.Path
				$installParams = SystemBitness $item.Params
				Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Install App - $($XML.Application.Name)] -- install started: $installPath with parameters $installParams"
				$process = Start-Process -FilePath $installPath -ArgumentList $installParams -Verb RunAs -PassThru
			}
			
			$Global:rebootAllowed = $true
			$handle = $process.Handle
			$process.WaitForExit()
			$cleanInstall = $process.ExitCode
			Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Install App - $($XML.Application.Name)] -- install finished: $($process.ExitCode)"
			$ocsInitiate = $true			
		}
		catch
		{
			#ispis greške na ekranu
			Write-Host "    $(Get-Date -format 'HH:mm:ss') -- error occured during installation`r`n    -- Error - $($_.Exception.Message)"
			$cleanInstall = -1
			Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Install App - $($XML.Application.Name)] -- $($_.Exception.Message)"
		}
	}
	return $cleanInstall
}

## funkcija koja pretvara verzije u numeričke vrijednosti i provjerava koja je veća
function VersionComparison ([string]$current, [string]$installer)
{
	$value = $true
	
	$delimsCurrent = [string]([regex]::Matches($current, "[^0-9]") | Select-Object -unique) -replace "\s", ""
	$delimsInstaller = [string]([regex]::Matches($installer, "[^0-9]") | Select-Object -unique) -replace "\s", ""
	
	if ([string]::IsNullOrEmpty($delimsCurrent) -and [string]::IsNullOrEmpty($delimsInstaller))
	{
		if ([int]$current -ge [int]$installer)
		{	
			$value = $false
		}
	}
	else
	{
		$currArray = $current.Split($delimsCurrent) | Where-Object {$_}
		$instArray = $installer.Split($delimsInstaller) | Where-Object {$_}
		
		if ($currArray.Count -ge $instArray.Count)
		{
			$arrayLength = $instArray.Count
		}
		else
		{
			$arrayLength = $currArray.Count
		}

		for ($i = 0; $i -lt $arrayLength; $i++)
		{	
			if ([int]($currArray[$i]) -gt [int]($instArray[$i]))
			{
				$value = $false
				break
			} 
			elseif ([int]($currArray[$i]) -eq [int]($instArray[$i]))
			{
				$value = $false
				continue
			}
			else
			{
				$value = $true
				break
			}
		}
	}
	return $value
}

## funkcija koja vrši provjeru verzija ovisno parametru unutar XML datoteke
function VersionCheck
{
	$proceed = $true
	
	# provjera da li se verzija uopće uzima u obzir, korisno kod reinstalacije iste aplikacije
	if (!([System.Convert]::ToBoolean($XML.Application.Version.Initiate)) -or $f)
	{
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - ignoring version..."
		return $proceed
	}

	Write-Host "    $(Get-Date -format 'HH:mm:ss') - checking versions..."
	# provjera da li postoji EXE path u xmlu preko kojeg se poziva ispis verzije
	if (!([string]::IsNullOrEmpty($XML.Application.Version.EXE.Path)))
	{
		$versionEXE = SystemBitness $XML.Application.Version.EXE.Path
		$versionParams = SystemBitness $XML.Application.Version.EXE.Params
		if (Test-Path $versionEXE)
		{
			try
			{
				$appVersion = & $versionEXE $versionParams | Write-Output					
				$isValid = VersionComparison $appVersion $XML.Application.Install.Installer.InstallVersion
				
				if (!$isValid)
				{
					$proceed = $false
					Write-Host "    $(Get-Date -format 'HH:mm:ss') - current version -> $appVersion"
					Write-Host "    $(Get-Date -format 'HH:mm:ss') - installer version -> $($XML.Application.Install.Installer.InstallVersion)"
					return $proceed
				}
			}
			catch
			{
				$proceed = $true
				$appVersion = " - couldn't get version from -> $($XML.Application.Version.EXE.Path) $($XML.Application.Version.EXE.Params)"
				Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Version Check EXE - $($XML.Application.Name)] -- $($_.Exception.Message)"
			}
		}
		else
		{
			$proceed = $true
			$appVersion = "application not found -> $($XML.Application.Version.EXE.Path)"
		}
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - current version -> $appVersion"
	}
	
	# provjera da li postoji Registry key preko kojega se uzima trenutna verzija aplikacije na računalu
	if (!([string]::IsNullOrEmpty($XML.Application.Version.Registry.Key)))
	{
		$regHive = $XML.Application.Version.Registry.Hive			
		try
		{
			if ($regHive.Substring(($regHive.IndexOf("\") - 1), 1) -ne ":") 
			{ 
				$regHive = "Registry::$($XML.Application.Version.Registry.Hive)"
			}
		}
		catch {	}
		
		if (Test-Path $regHive)
		{	
			try
			{
				$appVersion = Get-ItemProperty -Path $regHive -Name $XML.Application.Version.Registry.Key | select -exp $XML.Application.Version.Registry.Key
				$isValid = VersionComparison $appVersion $XML.Application.Install.Installer.InstallVersion
				
				if (!$isValid)
				{
					$proceed = $false
					Write-Host "    $(Get-Date -format 'HH:mm:ss') - current version -> $appVersion"
					Write-Host "    $(Get-Date -format 'HH:mm:ss') - installer version -> $($XML.Application.Install.Installer.InstallVersion)"
					return $proceed
				}
			}
			catch
			{
				$proceed = $true
				$appVersion = " - registry value not found -> $regHive"
				Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Version Check REGISTRY - $($XML.Application.Name)] -- $($_.Exception.Message)"
			}
		}
		else
		{
			$proceed = $true
			$appVersion = "registry key not found -> $($XML.Application.Version.Registry.Hive)"
		}
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - current version -> $appVersion"
	}
	
	# provjera da li postoji datoteka koja ima verziju u Details tabu.
	if (!([string]::IsNullOrEmpty($XML.Application.Version.File.Path)))
	{
		$versionFile = SystemBitness $XML.Application.Version.File.Path
		if (Test-Path $versionFile)
		{
			try
			{
				$appVersion = (Get-Item -Path $versionFile).VersionInfo | select -exp FileVersion
				if (!$appVersion)
				{
					$versionFile = $versionFile.Replace("\", "\\")
					$wmiFileQueryResult = Get-WmiObject -Query "Select Version From CIM_DataFile Where Name='$versionFile'"
					$appVersion = $wmiFileQueryResult.Version
				}
				
				$isValid = VersionComparison $appVersion $XML.Application.Install.Installer.InstallVersion
				
				if (!$isValid)
				{
					$proceed = $false
					Write-Host "    $(Get-Date -format 'HH:mm:ss') - current version -> $appVersion"
					Write-Host "    $(Get-Date -format 'HH:mm:ss') - installer version -> $($XML.Application.Install.Installer.InstallVersion)"
					return $proceed
				}
			}
			catch
			{
				$proceed = $true
				$appVersion = " - cannot get version from file -> $($XML.Application.Version.File.Path)"
				Add-Content $errorLogger "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Version Check FILE - $($XML.Application.Name)] -- $($_.Exception.Message)"
			}
		}
		else
		{
			$proceed = $true
			$appVersion = "file not found -> $($XML.Application.Version.File.Path)"
		}
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - current version -> $appVersion"
	}

	Write-Host "    $(Get-Date -format 'HH:mm:ss') - installer version -> $($XML.Application.Install.Installer.InstallVersion)"
	return $proceed
}

## funkcija koja proverava da li je WMI condition zadovoljen
function WMICondition([string]$wmiRawQuery)
{	
	if ($c)
	{
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - ignoring condition..."
		return $true
	}
	
	
	if ([string]::IsNullOrEmpty($wmiRawQuery))
	{
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - condition query is empty!"
		return $false
	}
		
	$wmiQuery = SystemBitness $wmiRawQuery
	##  ovo je potencijalno opasno zbog mogućnosti expandanja powershell code-a ako je isti stavljen u XML file ##
	$wmiQuery = $ExecutionContext.InvokeCommand.ExpandString($wmiQuery)

	## ovdje se ispisuje ne ekspandirani query radi sigurnosti ako expandirani query sadrži neki opasan code
	Write-Host "    $(Get-Date -format 'HH:mm:ss') - executing condition query -> $wmiRawQuery"
	$wmiResult = $null
	
	try
	{
		$wmiResult = Get-WmiObject -Query $wmiQuery
	}
	catch 
	{
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - unable to execute WMI query!"
		AllDone
	}
	
	if (!$wmiResult)
	{
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - condition query result -> 'False'"
		return $false
	}
	else
	{
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - condition query result -> 'True'"
		return $true
	}
}

## funkcija koja raspoređuje daljnje zadatke prema parametrima definiranim u XML datoteci
function ScriptDispatcher
{
	# poziv provjere verzije i overwrite opcije
	if(!(VersionCheck))
	{
		# ukoliko VersionCheck funkcija vrati 'false' skripta se prekida
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - version check failed"
		
		AllDone
	}
	
	if(([System.Convert]::ToBoolean($XML.Application.CustomScript.Initiate)) -and ([System.Convert]::ToBoolean($XML.Application.CustomScript.HighPriority)))
	{
		$output = CustomScript
		if ($output -ne 0)
		{
			## ako High Priority skripta faila, sve se prekida...
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - high priority script failed"

			AllDone
		}
	}
	
	if(([System.Convert]::ToBoolean($XML.Application.Copy.Initiate)) -and ([System.Convert]::ToBoolean($XML.Application.Copy.HighPriority)))
	{
		CopyFile
	}
	
	if (([System.Convert]::ToBoolean($XML.Application.Remove.Initiate)) -and ([System.Convert]::ToBoolean($XML.Application.Remove.HighPriority)))
	{
		RemoveFile
	}	
	
	# provjera da li je potrebna deinstalacija PRIJE instalacije
	if (([System.Convert]::ToBoolean($XML.Application.Uninstall.Initiate)) -and ([System.Convert]::ToBoolean($XML.Application.Uninstall.HighPriority)))
	{
		$output = UninstallApp
		if ($output -ne 0)
		{
			#TODO: što ako uninstall faila ?
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - high priority uninstall returned code: $output"
		}
	}
	
	# provjera da li je potrebna instalacija
	if ([System.Convert]::ToBoolean($XML.Application.Install.Initiate))
	{
		$output = InstallApp
		if ($output -ne 0)
		{
			# ako install faila, neće se obaviti uninstall dio skripte
			$cleanInstall = $false
		}
	}
	
	# provjera da li postoje datoteke\direktoriji koje je potrebno kopirati
	if (([System.Convert]::ToBoolean($XML.Application.Copy.Initiate)) -and (!([System.Convert]::ToBoolean($XML.Application.Copy.HighPriority))))
	{
		CopyFile
	}
	
	# provjera da li postoje datoteke/direktoriji koje je potrebno ukloniti
	if ([System.Convert]::ToBoolean($XML.Application.Remove.Initiate) -and (!([System.Convert]::ToBoolean($XML.Application.Remove.HighPriority))))
	{
		RemoveFile
	}
		
	# provjera da li je potrebna deinstalacija 
	if ([System.Convert]::ToBoolean($XML.Application.Uninstall.Initiate) -and (![System.Convert]::ToBoolean($XML.Application.Uninstall.HighPriority)))
	{
		$output = UninstallApp
		if (!($output))
		{
			#TODO: što ako uninstall faila ?
		}
	}
	
	# provjera da li je potrebno pozvati dodatne skripte
	if(([System.Convert]::ToBoolean($XML.Application.CustomScript.Initiate)) -and (!([System.Convert]::ToBoolean($XML.Application.CustomScript.HighPriority))))
	{
		$output = CustomScript
		if ($output -ne 0)
		{
			## ako Low Priority skripta faila, što onda?
		}
	}
}

## funkcija za provjeru LOG datoteke i brisanje unosa starijih od '$logsSpanDays' dana
function CheckLogs
{
	Write-Host "    $(Get-Date -format 'HH:mm:ss') - checking logs..."
	
	$counter = 0
	$writeLine = [string]::Empty
	$stringBuilder = New-Object System.Text.StringBuilder
	
	$currentDate = (Get-Date -format "dd.MM.yyyy. HH:mm:ss")
	
	$parentFolder = Split-Path -Parent $errorLogger
	if (!(Test-Path $parentFolder))
	{
		New-Item $parentFolder -Type directory | Out-Null
	}
	if (!(Test-Path $errorLogger))
	{
		New-Item $errorLogger -Type file | Out-Null
	}
	else
	{
		try
		{	
			foreach ($line in (Get-Content $errorLogger))
			{				
				if ($line -ne [string]::Empty)
				{
					$lineDate = $line.Substring(0, $line.IndexOf("--")).Trim()							
					$timeSpan = [int](New-TimeSpan -Start ([datetime]::ParseExact($lineDate, "dd.MM.yyyy. HH:mm:ss", $null)) -End ([datetime]::ParseExact($currentDate, "dd.MM.yyyy. HH:mm:ss", $null))).TotalDays
					
					if ($timeSpan -le $logsSpanDays)
					{
						$stringBuilder.Append("$line`r`n") | Out-Null
					}
					else
					{
						$counter++
					}
				}
			}
			
			Remove-Item -Path $errorLogger -Force
			Add-Content $errorLogger $stringBuilder.ToString()
		}
		catch 
		{	
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - error accessing log file -> $errorLogger`r`n    -- Error - $($_.Exception.Message)"
		}
	}
	
	if ($counter -gt 0)
	{
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - logs truncated ($counter entries removed)"
	}
	
	Write-Host "    $(Get-Date -format 'HH:mm:ss') - error logs location -> $errorLogger"
}

## učitavanje XML datoteke sa parametrima instalacije
function ImportXML ([string]$XMLpath)
{
	try
	{
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - loading XML file -> $XMLpath"
		[xml]$XMLfile = Get-Content $XMLpath
		return $XMLfile
	}
	catch
	{
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - XML import error occured.`r`n    -- Error - $($_.Exception.Message)"
		Add-Content $errorLogger  "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [XML IMPORT - $($XML.Application.Name)] -- '$XMLpath' -- $($_.Exception.Message)"
		return $null
	}
}

## funkcija koja provjerava da li je već aktivna druga instanca ove skripte
function ScriptActivityCheck([bool]$firstTime)
{
	$isActive = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstaller" -ErrorAction SilentlyContinue | Select -exp "MasterInstaller"
	$wasStarted = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstallerStart" -ErrorAction SilentlyContinue | Select -exp "MasterInstallerStart"
	
	if ($isActive -And (($currentUNIXTime - [double]$wasStarted) -lt 1800))
	{
		if($firstTime)
		{
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - another install in progress -> $isActive"
			Add-Content $errorLogger  "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Script Activity Check - $($XML.Application.Name)] -- Another instace is running: $isActive"
		}
		
		return $false
	}
	else
	{	
		try
		{
			Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstaller" -Value $XML.Application.Name
			Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstallerStart" -Value $currentUNIXTime
		}
		catch
		{
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - no registry access, install flags are NOT set..."
		}
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - no installations in progress, continue with installation..."
		if ($waitPeriodCounter -ne 0)
		{
			$totalTime = $waitPeriodCounter * 2
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - installation was resumed -> waited $totalTime seconds"
			Add-Content $errorLogger  "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Wait Idle - $($XML.Application.Name)] -- Installation resumed, waited $totalTime seconds"
		}
		return $true
	}
}

## provjera da li neka skripta koja se već izvodi ima scheduled restart ako postoji, skripta se prekida
function RebootCheck
{
	$rebootScheduled = $null
	$rebootScheduled = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstallerReboot" -ErrorAction SilentlyContinue | Select -exp "MasterInstallerReboot"
	
	if ($rebootScheduled -And ($currentUNIXTime - [System.Math]::Round([double]::Parse($rebootScheduled)) -lt 1800))
	{
		$originTime = New-Object -Type DateTime -ArgumentList 1970, 1, 1, 0, 0, 0, 0
		$rebootScheduledTime = $originTime.AddSeconds($rebootScheduled)
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - WARNING -> reboot already scheduled at $rebootScheduledTime"
		AllDone
	}
	
	Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstallerReboot" -ErrorAction SilentlyContinue
	
	if ([System.Convert]::ToBoolean($XML.Application.Reboot))
	{
		Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstallerReboot" -Value $currentUNIXTime
		Write-Host "    $(Get-Date -format 'HH:mm:ss') - WARNING -> this installation has a scheduled restart once finished"
		$Global:rebootFlag = $true
	}
}
	
## funkcija koja ponovno pokreće sleep timer i izlazi iz skripte
function AllDone
{
	$isActive = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstaller" -ErrorAction SilentlyContinue | Select -exp "MasterInstaller"
	if ($isActive -eq $XML.Application.Name)
	{
		Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstaller"
		Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstallerStart"
	}
	## ponovno pokreni sleep timer kada završi skripta
	SleepManager $false
	Write-Host "    $(Get-Date -format 'HH:mm:ss') - finished...`n`n"
	
	if ([System.Convert]::ToBoolean($XML.Application.Reboot))
	{
		if ($Global:rebootFlag)
		{
			Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstallerReboot"
		}
		if ($Global:rebootAllowed)
		{
			Add-Content $errorLogger  "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [All Done - $($XML.Application.Name)] -- Installation finished, restart initiated..."
			Restart-Computer -Force
		}
	}
	
	if ($r)
	{
		Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "MasterInstallerReboot"
		Add-Content $errorLogger  "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [All Done - $($XML.Application.Name)] -- restart was forced with '-r' switch..."
		Restart-Computer -Force
	}
	
	## izlaz iz skripte
	Exit
}





####################################################
####											####
####	-=[   ENTRY POINT ZA SKRIPTU   ]=-		####
####											####
####################################################



Write-Host "`n"

## zaustavi sleep timer kada krene skripta ('$true' parametar zaustavlja sleep timer, '$false' ga opet pokreće)
SleepManager $true

## provjera da li je LOG file kreiran i spreman za upotrebu
CheckLogs
## uvoz XML datoteke u '$XML' varijablu
[xml]$XML = ImportXML $args[0]
## ukoliko je uvoz XML-a uspješan (i '$XML.Application.Initiate' ima vrijednost 'true') nastavlja se sa skriptom
if ([System.Convert]::ToBoolean($XML.Application.Initiate))
{	
	## provjera da li je schedulan Reboot 
	RebootCheck
	
	## poziv WMICondition funkcije i provjera da li je taj condition zadovoljen
	if ([System.Convert]::ToBoolean($XML.Application.Condition.Initiate))
	{
		$result = WMICondition $XML.Application.Condition.WMIQuery
		if ($result -ne [System.Convert]::ToBoolean($XML.Application.Condition.Result))
		{			
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - condition query failed -> should be '$([System.Convert]::ToBoolean($XML.Application.Condition.Result))'"
			AllDone
		}
	}
	
	## provjera da li je već neka instanca skripte aktivna
	if (!$m)
	{
		$waitPeriodCounter = 0
		$canProceeed = ScriptActivityCheck $true
		if (!$canProceeed)
		{
			while($waitPeriodCounter -lt $waitPeriod)
			{
				$waitPeriodCounter++
				Start-Sleep 2
				$canProceeed = ScriptActivityCheck $false
				if ($canProceeed)
				{
					break
				}
			}
			if (($waitPeriodCounter -ge $waitPeriod) -And (!$canProceeed))
			{
				$totalTime = $waitPeriodCounter * 2
				Write-Host "    $(Get-Date -format 'HH:mm:ss') - installation was blocked -> waited $totalTime seconds"
				Add-Content $errorLogger  "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [Wait Idle - $($XML.Application.Name)] -- Installation was blocked, waited $totalTime seconds"
				AllDone
			}
		}
	}

	## variabla koja se postavlja na true ukoliko se obavi neka promjena na sustavu (install/uninstall/custom script)
	$ocsInitiate = $false
	ScriptDispatcher
	Add-Content $errorLogger "`n"
	
	## pokretanje OCS Inventory skena da bi se promjene nakon instalacije poslale na OCS server ako je nešto instalirano
	$ocsExecutable = SystemBitness $ocsExecutable
	if ($ocsInitiate -And !([string]::IsNullOrEmpty($ocsExecutable)) -And (Test-Path $ocsExecutable))
	{
		try
		{
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - OCS synchronization started..."
			$process = Start-Process -FilePath $ocsExecutable -Verb RunAs -PassThru
		}
		catch 
		{
			Write-Host "    $(Get-Date -format 'HH:mm:ss') - OCS Inventory could not be started -> '$ocsExecutable'`r`n    -- Error - $($_.Exception.Message)"
			Add-Content $errorLogger  "$(Get-Date -format 'dd.MM.yyyy. HH:mm:ss') -- [OCS TRIGGER] -- OCS Inventory Scan failed -- $($_.Exception.Message)"
		}
	}
}
elseif ($XML)
{
	Write-Host "    $(Get-Date -format 'HH:mm:ss') - skipping current template -> $($XML.Application.Name) -> Initiate = '$($XML.Application.Initiate)'"
}

AllDone