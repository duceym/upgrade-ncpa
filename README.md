# upgrade-ncpa
PowerShell script that the Nagios check_ncpa utility can call which
will then upgrade the Nagios NCPA agent and other plugin files/scripts.
-------------------------------------------------------------------------------------------------
I wrote this plugin since I needed a way to upgrade the NCPA agent and other plugins, but did not have rights to log
into the system and install the agent from the command line.
So this way when you run check_ncpa, you can upgrade the agent remotely.
First you download the ncpa-latest.exe from Nagios and stage it on a local HTTP or FTP directory.
In that same directory you would also make a directory called scripts and store the plugins you wish to copy as well.
Use a helper script from your Nagios XI server to help you start the installations. (nagios_ncpa_upgrade_generic.sh)
If the NCPA agent that you try to install is less than or equal to the version you already have, it will skip the agent
installation but still copy the plugin scripts.
If you want to force an install or downgrade, use the -Force parameter as shown below.
The script will check ncpa-latest.exe to ensure it has been digitally signed by Nagios.
The 3.x.x NCPA agents are signed and the 2.x.x agents are not, so this only supports 3.x.x agents.
The script is self-updating — upgrade-ncpa.ps1 itself is included in the plugin list and will be copied
to the client on every run, keeping it current automatically.

## Directory Structure
Your HTTP or FTP server should be laid out as follows:
```
/ncpa/
  ncpa-latest.exe
  scripts/
    upgrade-ncpa.ps1
    check_services.ps1
    check_windows_time.bat
    ... (any other plugins)
```

## Usage

**HTTP:**
```bash
#!/bin/bash
NCPA_TOKEN="${2:-YOUR_NCPA_TOKEN}"

/usr/local/nagios/libexec/check_ncpa.py \
  -H $1 \
  -t $NCPA_TOKEN \
  -P 5693 \
  -M 'plugins/upgrade-ncpa.ps1' \
  -q "args=-SourceRoot http://servername/ncpa -Token $NCPA_TOKEN"
```

**FTP:**
```bash
#!/bin/bash
NCPA_TOKEN="${2:-YOUR_NCPA_TOKEN}"

/usr/local/nagios/libexec/check_ncpa.py \
  -H $1 \
  -t $NCPA_TOKEN \
  -P 5693 \
  -M 'plugins/upgrade-ncpa.ps1' \
  -q "args=-SourceRoot ftp://servername/ncpa -User nagios -Password nagios -Token $NCPA_TOKEN"
```

**Check installed version:**
```bash
/usr/local/nagios/libexec/check_ncpa.py \
  -H hostname \
  -t YOUR_NCPA_TOKEN \
  -P 5693 \
  -M 'plugins/upgrade-ncpa.ps1' \
  -q 'args=-Version'
```
Returns: `OK - upgrade-ncpa.ps1 version 1.0.0`

**Force reinstall or downgrade:**
```bash
#!/bin/bash
NCPA_TOKEN="${2:-YOUR_NCPA_TOKEN}"

/usr/local/nagios/libexec/check_ncpa.py \
  -H $1 \
  -t $NCPA_TOKEN \
  -P 5693 \
  -M 'plugins/upgrade-ncpa.ps1' \
  -q "args=-SourceRoot http://servername/ncpa -Token $NCPA_TOKEN -Force"
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-SourceRoot` | Yes | | Base HTTP or FTP URL where ncpa-latest.exe and scripts/ are hosted |
| `-Token` | Yes | | NCPA authentication token |
| `-User` | No | | Username for FTP authentication |
| `-Password` | No | | Password for FTP authentication |
| `-InstallerName` | No | `ncpa-latest.exe` | Installer filename on the server |
| `-PluginDir` | No | `C:\Program Files\Nagios\NCPA\plugins` | Destination for plugin scripts |
| `-WorkDir` | No | `C:\ProgramData\Nagios\NCPA-Upgrade` | Working directory for staging and logs |
| `-LockMinutes` | No | `60` | Minutes before a stale lock is cleared |
| `-Force` | No | | Bypass version check and force reinstall or downgrade |
| `-Version` | No | | Display script version and exit |


Questions or feedback: matthew_ducey@yahoo.com