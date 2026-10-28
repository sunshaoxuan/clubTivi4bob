param(
  [string]$ProcDumpPath,
  [string]$DumpFolder
)

# Retired compatibility entry point. Old local launchers may still reference
# this path. BobTV records native crashes in-process through Windows DbgHelp.
# Keep this script inert: no process, console, filesystem or scheduled-task work.
return
