local dir = os.getenv("TMPDIR") or "/tmp"
return { getSettingsDir = function() return dir end, getDataDir = function() return dir end }
