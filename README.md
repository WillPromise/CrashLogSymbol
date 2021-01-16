# CrashLogSymbol
symbolicate crash logs of iOS or macOS

## Requirement ##
Xcode installed

## Usage ##

```shell
chmod +x ./symbolicate.sh
./symbolicate.sh -h
./symbolicate.sh -f /path/to/crashlog
```

## Limitation ##
- for iOS Crash Log, this script needs `~/Library/Developer/Xcode/iOS DeviceSupport/XXX` to symbolicate System framework's functions
- for macOS Crash Log, this script will not symbolicate System framework's functions
