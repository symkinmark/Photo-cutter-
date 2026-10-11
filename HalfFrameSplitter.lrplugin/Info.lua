--[[----------------------------------------------------------------------------
Info.lua - Half-Frame Splitter for Lightroom Classic

Splits half-frame (e.g. Olympus Pen, Pentax 17, Kodak Ektar H35) pair scans
into two virtual copies, cropped at the black line between the frames.

Keep LrToolkitIdentifier unchanged across versions: Lightroom stores the
plug-in's settings under it.
------------------------------------------------------------------------------]]

return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = 'com.github.symkinmark.halfframesplitter',
	LrPluginName = 'Half-Frame Splitter',
	LrPluginInfoUrl = 'https://github.com/symkinmark/photo-cutter-',
	LrPluginInfoProvider = 'HFSPluginInfo.lua',

	-- Library > Plug-in Extras
	LrLibraryMenuItems = {
		{
			title = 'Split Half-Frame Pairs...',
			file = 'HFSMenuSplit.lua',
			enabledWhen = 'photosSelected',
		},
	},

	-- File > Plug-in Extras (also available in the Develop module)
	LrExportMenuItems = {
		{
			title = 'Split Half-Frame Pairs...',
			file = 'HFSMenuSplit.lua',
			enabledWhen = 'photosSelected',
		},
	},

	VERSION = { major = 1, minor = 0, revision = 0, build = 0, display = '1.0.0' },
}
