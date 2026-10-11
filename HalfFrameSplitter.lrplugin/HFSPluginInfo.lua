--[[----------------------------------------------------------------------------
HFSPluginInfo.lua - the panel shown in File > Plug-in Manager.
------------------------------------------------------------------------------]]

local HFSMain = require 'HFSMain'

return {
	sectionsForTopOfDialog = function(f, _)
		return {
			{
				title = 'Half-Frame Splitter ' .. HFSMain.VERSION,
				f:column {
					spacing = f:control_spacing(),
					f:static_text {
						title = 'Splits half-frame pair scans into two virtual copies ("Half 1" and "Half 2"), '
							.. 'cropped at the black line between the frames. Originals are never changed.\n\n'
							.. 'Use: select the pair scans, then Library > Plug-in Extras > Split Half-Frame Pairs... '
							.. '(or File > Plug-in Extras in the Develop module).\n\n'
							.. 'Unclear pairs are collected in "Half-Frame Splitter > Needs review". '
							.. 'A log is written to HalfFrameSplitter.log in the Lightroom logs folder '
							.. '(Documents/LrClassicLogs).',
						width_in_chars = 70,
						height_in_lines = 8,
					},
				},
			},
		}
	end,
}
