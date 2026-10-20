Option Explicit
' 静默启动模型消耗小组件（不闪黑框）
Dim fso, sh, base, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = base
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\ModelUsageWidget.ps1"""
sh.Run cmd, 0, False
