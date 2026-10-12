--[[----------------------------------------------------------------------------
HFSMain.lua
Half-Frame Splitter - the Lightroom side: dialog, analysis, virtual copies.

What happens when you run "Split Half-Frame Pairs...":
  1. Each selected photo is read (read-only) with macOS's built-in `sips`
     tool, which writes a small temporary BMP preview. The preview is
     analysed in Lua to find the black dividing line.
  2. Lightroom creates two virtual copies of the photo, named "Half 1" and
     "Half 2". Virtual copies are only sets of edit instructions in the
     catalog: no pixels are copied, nothing is re-encoded, and the original
     file and its own settings stay exactly as they were.
  3. Each virtual copy gets a crop that shows one of the two frames.
  4. Pairs where the line was unclear go into the collection
     "Half-Frame Splitter > Needs review".
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrLogger = import 'LrLogger'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local HFSImage = require 'HFSImage'
local HFSDetect = require 'HFSDetect'

local M = {}

M.VERSION = '1.1.0'
M.SIPS = '/usr/bin/sips'
M.ANALYSIS_SIZE = 1200      -- long side of the analysis preview, in pixels
M.QUESTION_SIZE = 560       -- long side of the preview shown when asking
M.BINS = 32                 -- brightness histogram bins
M.HALF_NAMES = { 'Half 1', 'Half 2' }
M.COLLECTION_SET = 'Half-Frame Splitter'
M.REVIEW_COLLECTION = 'Needs review'
M.TITLE = 'Half-Frame Splitter'

M.DEFAULTS = {
	fallback = 'ask',     -- 'ask': show the scan and ask, 'split': best guess + review,
	                      -- 'skip': only mark for review
	extraTrim = 0.3,      -- percent of the long side, removed on each side of the cut
	trimBorders = false,
}

local logger = LrLogger('HalfFrameSplitter')
logger:enable('logfile')

local function log(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	logger:info(ok and msg or tostring(fmt))
end

--------------------------------------------------------------------------------
-- Files and the `sips` tool

local function shellQuote(s)
	return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

local function readFile(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local data = f:read('*a')
	f:close()
	return data
end

local function writeFile(path, data)
	local f = io.open(path, 'wb')
	if not f then return false end
	f:write(data)
	f:close()
	return true
end

local tempCounter = 0
local function tempPath(ext)
	tempCounter = tempCounter + 1
	local dir = LrPathUtils.getStandardFilePath('temp')
	local name = string.format('hfs-%d-%d-%d.%s', os.time(), math.random(100000, 999999), tempCounter, ext)
	return LrPathUtils.child(dir, name)
end

-- Deletes one of our own temporary files. Refuses anything else, so a user's
-- photo can never be deleted by mistake.
local function deleteTemp(path)
	local leaf = LrPathUtils.leafName(path)
	if not leaf or not leaf:match('^hfs%-') then
		log('refusing to delete non-temporary file %s', tostring(path))
		return
	end
	if LrFileUtils.exists(path) then LrFileUtils.delete(path) end
end

local function runSips(args)
	local logPath = tempPath('log')
	local cmd = M.SIPS .. ' ' .. args .. ' >' .. shellQuote(logPath) .. ' 2>&1'
	local status = LrTasks.execute(cmd)
	local output = readFile(logPath) or ''
	deleteTemp(logPath)
	return status, output
end

--- Renders a small BMP preview of an image file with `sips` (read-only on
-- the source). Returns the BMP data or nil, error message.
function M.renderPreview(path)
	local out = tempPath('bmp')
	local status, output = runSips(string.format('-s format bmp -Z %d %s --out %s',
		M.ANALYSIS_SIZE, shellQuote(path), shellQuote(out)))
	local data = readFile(out)
	deleteTemp(out)
	if not data or #data == 0 then
		output = (output or ''):gsub('%s+$', '')
		log('sips failed (%s) for %s: %s', tostring(status), path, output)
		return nil, 'macOS could not read this image' .. (output ~= '' and (' (' .. output .. ')') or '')
	end
	return data
end

-- Whether `sips` turns pixels upright according to the orientation tag, per
-- file kind ('jpeg', 'tiff'). Found out once per Lightroom session with a
-- tiny test image that is wider than tall and tagged "rotate 90 degrees".
local sipsAppliesOrientation = {}

function M.sipsAppliesOrientation(kind)
	if sipsAppliesOrientation[kind] ~= nil then return sipsAppliesOrientation[kind] end
	local probe = kind == 'tiff' and HFSImage.makeOrientationProbeTiff() or HFSImage.makeOrientationProbeJpeg()
	local src = tempPath(kind == 'tiff' and 'tif' or 'jpg')
	local bmp = tempPath('bmp')
	local result = false
	if writeFile(src, probe) then
		runSips('-s format bmp ' .. shellQuote(src) .. ' --out ' .. shellQuote(bmp))
		local data = readFile(bmp)
		local h = data and HFSImage.parseBMPHeader(data)
		if h then
			result = h.height > h.width
			log('orientation probe (%s): sips output %dx%d -> applies orientation: %s',
				tostring(kind), h.width, h.height, tostring(result))
		else
			log('orientation probe (%s) failed; assuming sips keeps the stored pixel orientation', tostring(kind))
		end
	end
	deleteTemp(src)
	deleteTemp(bmp)
	sipsAppliesOrientation[kind] = result
	return result
end

--------------------------------------------------------------------------------
-- Analysis of one photo

--- Finds the two crops for a photo. Returns an analysis table or nil, error.
function M.analyzePhoto(path, lrOrientation, settings)
	local exifOrientation, kind = HFSImage.readOrientation(path)
	local data, err = M.renderPreview(path)
	if not data then return nil, err end
	local img, decodeErr = HFSImage.decodeBMPHistograms(data, M.BINS)
	data = nil
	if not img then return nil, 'could not read the preview (' .. tostring(decodeErr) .. ')' end

	local det = HFSDetect.analyze(img, { trimBorders = settings.trimBorders })
	local analysis = {
		det = det,
		path = path,
		lrOrientation = lrOrientation,
		exifOrientation = exifOrientation,
		-- the EXIF orientation sips already applied to its preview, if any
		exifApplied = (exifOrientation and exifOrientation ~= 1 and kind and M.sipsAppliesOrientation(kind))
			and exifOrientation or nil,
	}
	local rects, method = HFSDetect.computeCrops(det, { extraTrimPercent = settings.extraTrim })
	analysis.rects = M.finalizeRects(rects, analysis)
	analysis.method = method

	log('%s: %dx%d axis=%s found=%s confident=%s gap=%.4f..%.4f contrast=%.0f method=%s exif=%s lr=%s %s',
		path, img.width, img.height, tostring(det.axis), tostring(det.found), tostring(det.confident),
		det.gapStart or -1, det.gapEnd or -1, det.contrast or -1, method,
		tostring(exifOrientation), tostring(lrOrientation), table.concat(det.reasons, '; '))

	return analysis
end

--- Turns two crops measured on the analysed image into Lightroom crops,
-- ordered as shown on screen ("Half 1" first).
function M.finalizeRects(rects, analysis)
	-- Lightroom's crop values refer to the pixels as stored in the file. If
	-- sips turned the preview upright, map the crops back.
	if analysis.exifApplied then
		rects = {
			HFSDetect.exifRectToStored(rects[1], analysis.exifApplied),
			HFSDetect.exifRectToStored(rects[2], analysis.exifApplied),
		}
	end
	return HFSDetect.orderForDisplay(rects, analysis.lrOrientation)
end

--------------------------------------------------------------------------------
-- Catalog helpers

local function photoName(photo)
	local ok, name = LrTasks.pcall(function() return photo:getFormattedMetadata('fileName') end)
	return ok and name or '?'
end

--- Returns { [1] = vc or nil, [2] = vc or nil } for existing "Half 1"/"Half 2" copies.
function M.findHalves(photo)
	local found = {}
	local vcs = photo:getRawMetadata('virtualCopies') or {}
	for _, vc in ipairs(vcs) do
		local name = vc:getFormattedMetadata('copyName')
		for i, n in ipairs(M.HALF_NAMES) do
			if name == n then found[i] = vc end
		end
	end
	return found
end

local function sameSet(a, b)
	if #a ~= #b then return false end
	local seen = {}
	for _, p in ipairs(a) do seen[p.localIdentifier or p] = true end
	for _, p in ipairs(b) do
		if not seen[p.localIdentifier or p] then return false end
	end
	return true
end

local function selectExactly(catalog, photos)
	local rest = {}
	for i = 2, #photos do rest[#rest + 1] = photos[i] end
	catalog:setSelectedPhotos(photos[1], rest)
	for _ = 1, 20 do
		if sameSet(catalog:getTargetPhotos(), photos) then return true end
		LrTasks.sleep(0.1)
	end
	return false
end

local function createVirtualCopy(catalog, name)
	local result
	local ok, err = LrTasks.pcall(function() result = catalog:createVirtualCopies(name) end)
	if not ok then
		local msg = tostring(err)
		if msg:find('withWriteAccessDo') or msg:lower():find('write access') then
			catalog:withWriteAccessDo('Create half-frame copy', function()
				result = catalog:createVirtualCopies(name)
			end, { timeout = 30 })
		else
			error(err, 0)
		end
	end
	return result
end

-- Lightroom's virtual copy command acts on the selection, in the grid.
local function showLibraryGrid()
	LrTasks.pcall(function()
		if LrApplicationView.getCurrentModuleName() ~= 'library' then
			LrApplicationView.switchToModule('library')
		end
		LrApplicationView.showView('grid')
	end)
end

--- Creates one virtual copy of `photo` named `name`. One photo at a time, so
-- the new copy is known for certain. Returns the copy or nil, reason.
function M.createHalf(catalog, photo, name)
	local before = {}
	for _, vc in ipairs(photo:getRawMetadata('virtualCopies') or {}) do
		before[vc.localIdentifier] = true
	end
	if not selectExactly(catalog, { photo }) then
		return nil, 'could not select it in the current view (is it hidden by a filter or a collapsed stack?)'
	end
	createVirtualCopy(catalog, name)

	local copy
	for _ = 1, 30 do
		for _, vc in ipairs(photo:getRawMetadata('virtualCopies') or {}) do
			if not before[vc.localIdentifier] then copy = vc end
		end
		if copy then break end
		LrTasks.sleep(0.1)
	end
	if not copy then return nil, 'Lightroom did not create the virtual copy' end

	if copy:getFormattedMetadata('copyName') ~= name then
		local ok, err = LrTasks.pcall(function()
			catalog:withWriteAccessDo('Name half-frame copy', function()
				copy:setRawMetadata('copyName', name)
			end, { timeout = 10 })
		end)
		if not ok then log('could not name the copy %s: %s', name, tostring(err)) end
	end
	return copy
end

--------------------------------------------------------------------------------
-- Dialog

function M.validFallback(v)
	if v == 'split' or v == 'skip' or v == 'ask' then return v end
	return M.DEFAULTS.fallback
end

function M.showDialog(context, count)
	local prefs = LrPrefs.prefsForPlugin()
	local props = LrBinding.makePropertyTable(context)
	props.fallback = M.validFallback(prefs.fallback)
	props.extraTrim = tonumber(prefs.extraTrim) or M.DEFAULTS.extraTrim
	props.trimBorders = prefs.trimBorders == true

	local f = LrView.osFactory()
	local bind = LrView.bind
	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),
		f:static_text {
			title = string.format('%d photo%s selected. Each half-frame pair scan gets two virtual copies, '
				.. '"Half 1" and "Half 2", cropped at the black dividing line.\n'
				.. 'The original photos are never changed.', count, count == 1 and '' or 's'),
			width_in_chars = 62,
			height_in_lines = 3,
		},
		f:group_box {
			title = 'When the dividing line is unclear',
			fill_horizontal = 1,
			f:radio_button {
				title = 'Ask me: show the scan and let me choose where to cut',
				value = bind 'fallback',
				checked_value = 'ask',
			},
			f:radio_button {
				title = 'Split at the best guess (or the middle) and add to "Needs review"',
				value = bind 'fallback',
				checked_value = 'split',
			},
			f:radio_button {
				title = 'Do not split; only add the original to "Needs review"',
				value = bind 'fallback',
				checked_value = 'skip',
			},
		},
		f:group_box {
			title = 'Crop',
			fill_horizontal = 1,
			f:row {
				f:static_text { title = 'Extra trim at the cut:' },
				f:slider { value = bind 'extraTrim', min = 0, max = 2, width = 160 },
				f:edit_field { value = bind 'extraTrim', min = 0, max = 2, precision = 2, width_in_digits = 4 },
				f:static_text { title = '% of the width, each side' },
			},
			f:checkbox {
				title = 'Also crop away black borders around the pair (experimental)',
				value = bind 'trimBorders',
			},
		},
	}

	local result = LrDialogs.presentModalDialog {
		title = 'Split Half-Frame Pairs',
		contents = contents,
		actionVerb = 'Split',
	}
	if result ~= 'ok' then return nil end

	local extraTrim = tonumber(props.extraTrim) or M.DEFAULTS.extraTrim
	if extraTrim < 0 then extraTrim = 0 elseif extraTrim > 2 then extraTrim = 2 end
	local settings = {
		fallback = M.validFallback(props.fallback),
		extraTrim = extraTrim,
		trimBorders = props.trimBorders == true,
	}
	prefs.fallback = settings.fallback
	prefs.extraTrim = settings.extraTrim
	prefs.trimBorders = settings.trimBorders
	return settings
end

--------------------------------------------------------------------------------
-- "I can't see the line - where should I cut?"

--- Renders the scan small, as 24-bit pixel rows (analysed orientation).
function M.loadQuestionPreview(path)
	local out = tempPath('bmp')
	runSips(string.format('-s format bmp -Z %d %s --out %s', M.QUESTION_SIZE, shellQuote(path), shellQuote(out)))
	local data = readFile(out)
	deleteTemp(out)
	if not data then return nil end
	return (HFSImage.decodeBMPRows(data))
end

--- Writes a JPEG of the preview with red lines at `positions` (fractions
-- along `axis` of the analysed image), turned `rotation` degrees clockwise
-- so it looks like it does in Lightroom. Returns the JPEG path or nil.
function M.writeMarkedPreview(preview, axis, positions, rotation)
	local thickness = math.max(2, math.floor(math.max(preview.width, preview.height) / 250))
	local marked = HFSImage.drawLines(preview, axis, positions, { 255, 32, 32 }, thickness)
	local bmp = tempPath('bmp')
	local jpg = tempPath('jpg')
	if not writeFile(bmp, HFSImage.encodeBMP24(marked)) then return nil end
	local rotate = rotation ~= 0 and string.format('-r %d ', rotation) or ''
	runSips('-s format jpeg ' .. rotate .. shellQuote(bmp) .. ' --out ' .. shellQuote(jpg))
	deleteTemp(bmp)
	if not LrFileUtils.exists(jpg) then return nil end
	return jpg
end

--- Shows one unclear scan and asks where to cut it.
-- Returns { action = 'cut', rects = ..., position = percent } or
-- { action = 'skip' } or { action = 'cancel' }; plus rest = true when the
-- remaining unclear scans should use the best guess without asking.
function M.askWhereToCut(context, item, index, count, settings)
	local analysis = item.analysis
	local det = analysis.det
	local axis = det.axis or 'x'
	local rotation = HFSDetect.previewRotation(analysis.lrOrientation, analysis.exifApplied)
	local fromLeft, reversed = HFSDetect.displayDirection(axis, rotation)

	-- Positions: fractions of the analysed image <-> percent on screen.
	local function toScreen(pos)
		local v = (reversed and (1 - pos) or pos) * 100
		return math.floor(v * 10 + 0.5) / 10
	end
	local function fromScreen(percent)
		local p = percent / 100
		return reversed and (1 - p) or p
	end

	local guess = (det.found and det.usableGuess) and (det.gapStart + det.gapEnd) / 2 or nil
	local guessPercent = guess and toScreen(guess)
	local function isGuess(percent)
		return guessPercent ~= nil and math.abs(percent - guessPercent) < 0.05
	end
	-- What to draw: the edges of the guessed band, or the chosen cut line.
	local function linesFor(percent)
		if isGuess(percent) then return { det.gapStart, det.gapEnd } end
		return { fromScreen(percent) }
	end

	local props = LrBinding.makePropertyTable(context)
	props.position = guessPercent or 50
	props.choice = 'cut'
	props.rest = false

	local preview = M.loadQuestionPreview(analysis.path)
	local files, closed = {}, false
	local function render()
		if not preview then return end
		local jpg = M.writeMarkedPreview(preview, axis, linesFor(tonumber(props.position) or 50), rotation)
		if not jpg then return end
		if closed then
			deleteTemp(jpg)
		else
			files[#files + 1] = jpg
			props.preview = jpg
		end
	end
	render()

	-- Redraw the line while the slider moves (one redraw at a time).
	local busy, dirty = false, false
	props:addObserver('position', function()
		if busy then
			dirty = true
			return
		end
		busy = true
		LrTasks.startAsyncTask(function()
			repeat
				dirty = false
				LrTasks.pcall(render)
			until not dirty or closed
			busy = false
		end)
	end)

	local f = LrView.osFactory()
	local bind = LrView.bind
	local reason = table.concat(det.reasons, '; ')
	local c = { bind_to_object = props, spacing = f:control_spacing() }
	c[#c + 1] = f:static_text {
		title = string.format('I can\'t see the dividing line clearly in "%s" (%d of %d unclear).\n'
			.. 'Reason: %s.\nHow should I cut it?', item.name, index, count, reason),
		width_in_chars = 70,
		height_in_lines = 3,
	}
	if preview and props.preview then
		local w, h = preview.width, preview.height
		if rotation == 90 or rotation == 270 then w, h = h, w end
		c[#c + 1] = f:picture { value = bind 'preview', width = w, height = h, frame_width = 1 }
	else
		c[#c + 1] = f:static_text { title = '(No preview available - the position is still applied.)' }
	end
	c[#c + 1] = f:radio_button {
		title = 'Cut at the red line',
		value = bind 'choice',
		checked_value = 'cut',
	}
	c[#c + 1] = f:row {
		f:static_text { title = 'Position:' },
		f:slider { value = bind 'position', min = 5, max = 95, width = 300 },
		f:edit_field { value = bind 'position', min = 5, max = 95, precision = 1, width_in_digits = 5 },
		f:static_text { title = fromLeft and '% from the left' or '% from the top' },
	}
	local buttons = {
		f:push_button { title = 'Middle', action = function() props.position = 50 end },
	}
	if guessPercent then
		buttons[#buttons + 1] = f:push_button {
			title = 'My best guess',
			action = function() props.position = guessPercent end,
		}
	end
	c[#c + 1] = f:row(buttons)
	c[#c + 1] = f:radio_button {
		title = 'Don\'t cut it (add the original to "Needs review")',
		value = bind 'choice',
		checked_value = 'skip',
	}
	if count - index > 0 then
		c[#c + 1] = f:checkbox {
			title = string.format('Don\'t ask about the other %d unclear scan%s: cut at my best guess '
				.. 'and add them to "Needs review"', count - index, count - index == 1 and '' or 's'),
			value = bind 'rest',
		}
	end

	local result = LrDialogs.presentModalDialog {
		title = 'Where should I cut?',
		contents = f:column(c),
		actionVerb = 'OK',
		cancelVerb = 'Cancel all',
	}
	closed = true
	for _, path in ipairs(files) do deleteTemp(path) end

	if result ~= 'ok' then return { action = 'cancel' } end
	local rest = props.rest == true
	if props.choice == 'skip' then return { action = 'skip', rest = rest } end

	local percent = tonumber(props.position) or 50
	if percent < 1 then percent = 1 elseif percent > 99 then percent = 99 end
	local rects
	if isGuess(percent) then
		rects = HFSDetect.computeCrops(det, { extraTrimPercent = settings.extraTrim })
	else
		rects = HFSDetect.cropsAt(axis, fromScreen(percent), det.borders, settings.extraTrim)
	end
	log('%s: cut chosen by user at %.1f%% %s', item.name, percent, fromLeft and 'from the left' or 'from the top')
	return { action = 'cut', rects = M.finalizeRects(rects, analysis), position = percent, rest = rest }
end

--------------------------------------------------------------------------------
-- Summary

local function listLines(items, maxLines)
	local lines = {}
	for i, item in ipairs(items) do
		if i > maxLines then
			lines[#lines + 1] = string.format('   ...and %d more (details in the plug-in log)', #items - maxLines)
			break
		end
		lines[#lines + 1] = '   - ' .. item.name .. ': ' .. item.reason
	end
	return table.concat(lines, '\n')
end

local function summary(report)
	local parts = {}
	local nSplit = #report.split
	if nSplit > 0 then
		parts[#parts + 1] = string.format('Split %d pair%s into %d halves ("Half 1" and "Half 2", stacked with the original).',
			nSplit, nSplit == 1 and '' or 's', nSplit * 2)
		if (report.chosen or 0) > 0 then
			parts[#parts] = parts[#parts] .. string.format(' %d of them %s cut where you chose.',
				report.chosen, report.chosen == 1 and 'was' or 'were')
		end
	else
		parts[#parts + 1] = 'No photos were split.'
	end
	if #report.review > 0 then
		parts[#parts + 1] = string.format('%d need%s a look - see the collection "%s > %s":\n%s',
			#report.review, #report.review == 1 and 's' or '', M.COLLECTION_SET, M.REVIEW_COLLECTION,
			listLines(report.review, 10))
	end
	if #report.skipped > 0 then
		parts[#parts + 1] = string.format('Skipped %d:\n%s', #report.skipped, listLines(report.skipped, 8))
	end
	if #report.errors > 0 then
		parts[#parts + 1] = string.format('Problems with %d:\n%s', #report.errors, listLines(report.errors, 8))
	end
	parts[#parts + 1] = 'Original photos were not changed.'
	return table.concat(parts, '\n\n')
end

--------------------------------------------------------------------------------
-- Main

--- A split at the best guess (or the middle), marked for review.
function M.guessJob(photo, name, analysis)
	local how = analysis.method == 'middle' and 'split in the middle' or 'split at the best guess'
	return {
		photo = photo, name = name, rects = analysis.rects,
		review = table.concat(analysis.det.reasons, '; ') .. ' - ' .. how,
	}
end

function M.process(context)
	if WIN_ENV then
		LrDialogs.message(M.TITLE, 'This plug-in uses the macOS image tool "sips" and currently runs on macOS only.', 'critical')
		return
	end

	local catalog = LrApplication.activeCatalog()
	local targets = catalog:getTargetPhotos()
	if not targets or #targets == 0 then
		LrDialogs.message(M.TITLE, 'Select one or more half-frame pair scans first.', 'info')
		return
	end

	local settings = M.showDialog(context, #targets)
	if not settings then return end
	log('--- run v%s: %d photo(s), fallback=%s extraTrim=%.2f trimBorders=%s',
		M.VERSION, #targets, settings.fallback, settings.extraTrim, tostring(settings.trimBorders))

	local report = { split = {}, review = {}, skipped = {}, errors = {} }
	local jobs = {}
	local reviewPhotos = {}
	local unclear = {}

	local progress = LrProgressScope {
		title = 'Splitting half-frame pairs',
		functionContext = context,
	}

	-- 1. Analyse (read-only).
	local total = #targets
	for i, photo in ipairs(targets) do
		if progress:isCanceled() then break end
		local name = photoName(photo)
		progress:setCaption('Analysing ' .. name)
		progress:setPortionComplete(i - 1, total * 1.25)

		local ok, err = LrTasks.pcall(function()
			if photo:getRawMetadata('isVirtualCopy') then
				report.skipped[#report.skipped + 1] = { name = name, reason = 'is a virtual copy (select the original instead)' }
				return
			end
			if photo:getRawMetadata('fileFormat') == 'VIDEO' then
				report.skipped[#report.skipped + 1] = { name = name, reason = 'is a video' }
				return
			end
			local existing = M.findHalves(photo)
			if existing[1] or existing[2] then
				report.skipped[#report.skipped + 1] = { name = name,
					reason = 'already split (delete its "Half 1"/"Half 2" copies to split it again)' }
				return
			end
			local path = photo:getRawMetadata('path')
			if not path or not LrFileUtils.exists(path) then
				report.errors[#report.errors + 1] = { name = name, reason = 'the file is missing or its drive is not connected' }
				return
			end
			local ds = photo:getDevelopSettings() or {}
			local analysis, aerr = M.analyzePhoto(path, ds.orientation, settings)
			if not analysis then
				report.errors[#report.errors + 1] = { name = name, reason = aerr }
				return
			end
			local det = analysis.det
			local reason = table.concat(det.reasons, '; ')
			if det.confident then
				jobs[#jobs + 1] = { photo = photo, name = name, rects = analysis.rects }
			elseif settings.fallback == 'skip' then
				report.review[#report.review + 1] = { name = name, reason = reason .. ' - not split' }
				reviewPhotos[#reviewPhotos + 1] = photo
			elseif settings.fallback == 'ask' then
				unclear[#unclear + 1] = { photo = photo, name = name, analysis = analysis }
			else
				jobs[#jobs + 1] = M.guessJob(photo, name, analysis)
			end
		end)
		if not ok then
			log('error analysing %s: %s', name, tostring(err))
			report.errors[#report.errors + 1] = { name = name, reason = tostring(err) }
		end
	end

	if progress:isCanceled() then
		progress:done()
		LrDialogs.message(M.TITLE, 'Cancelled. Nothing was changed.', 'info')
		return
	end

	-- 1b. Ask about the scans where the line could not be seen.
	local askRest = true
	for i, item in ipairs(unclear) do
		if askRest then
			progress:setCaption(string.format('Waiting for your answer (%d of %d)', i, #unclear))
			local answer = M.askWhereToCut(context, item, i, #unclear, settings)
			if answer.action == 'cancel' then
				progress:done()
				LrDialogs.message(M.TITLE, 'Cancelled. Nothing was changed.', 'info')
				return
			elseif answer.action == 'skip' then
				report.review[#report.review + 1] = { name = item.name, reason = 'you chose not to cut it' }
				reviewPhotos[#reviewPhotos + 1] = item.photo
			else
				jobs[#jobs + 1] = { photo = item.photo, name = item.name, rects = answer.rects, chosen = true }
			end
			if answer.rest then askRest = false end
		else
			jobs[#jobs + 1] = M.guessJob(item.photo, item.name, item.analysis)
		end
	end

	-- 2. Create the virtual copies.
	if #jobs > 0 then
		showLibraryGrid()
		for j, job in ipairs(jobs) do
			progress:setCaption('Creating virtual copies for ' .. job.name)
			progress:setPortionComplete(total + 0.2 * total * (j - 1) / #jobs, total * 1.25)
			job.halves = {}
			for i, name in ipairs(M.HALF_NAMES) do
				local ok, copy, err = LrTasks.pcall(M.createHalf, catalog, job.photo, name)
				if not ok then copy, err = nil, tostring(copy) end
				if not copy then
					job.error = err
					log('could not create %s for %s: %s', name, job.name, tostring(err))
					break
				end
				job.halves[i] = copy
			end
		end

		-- 3. Apply the crops. A half that was created is always cropped, even
		-- if its partner failed, so no uncropped copy is left behind.
		progress:setCaption('Applying crops')
		local status = catalog:withWriteAccessDo('Split half-frame pairs', function()
			for _, job in ipairs(jobs) do
				for i = 1, 2 do
					if job.halves[i] then
						job.halves[i]:applyDevelopSettings(HFSDetect.cropSettings(job.rects[i]), 'Half-Frame Splitter crop')
					end
				end
			end
		end, { timeout = 60 })
		if status == 'aborted' then
			error('Lightroom was busy and the crops could not be applied. Please try again.', 0)
		end

		for _, job in ipairs(jobs) do
			if job.error then
				local reason = job.error
				if job.halves[1] then
					reason = reason .. ' (only "Half 1" was made - delete it and run again)'
				end
				report.errors[#report.errors + 1] = { name = job.name, reason = reason }
			else
				report.split[#report.split + 1] = { name = job.name }
				if job.chosen then report.chosen = (report.chosen or 0) + 1 end
			end
			if job.review and job.halves[1] then
				report.review[#report.review + 1] = { name = job.name, reason = job.review }
				for i = 1, 2 do
					if job.halves[i] then reviewPhotos[#reviewPhotos + 1] = job.halves[i] end
				end
			end
		end
	end

	if #reviewPhotos > 0 then
		catalog:withWriteAccessDo('Half-frame pairs to review', function()
			local set = catalog:createCollectionSet(M.COLLECTION_SET, nil, true)
			local collection = catalog:createCollection(M.REVIEW_COLLECTION, set, true)
			collection:addPhotos(reviewPhotos)
		end, { timeout = 30 })
	end

	-- Put the selection back the way it was.
	LrTasks.pcall(function()
		local rest = {}
		for i = 2, #targets do rest[#rest + 1] = targets[i] end
		catalog:setSelectedPhotos(targets[1], rest)
	end)

	progress:done()

	for _, item in ipairs(report.errors) do log('problem: %s: %s', item.name, item.reason) end
	for _, item in ipairs(report.review) do log('review: %s: %s', item.name, item.reason) end
	LrDialogs.message(M.TITLE, summary(report), (#report.errors > 0) and 'warning' or 'info')
end

function M.run()
	LrFunctionContext.postAsyncTaskWithContext('HalfFrameSplitter', function(context)
		LrDialogs.attachErrorDialogToFunctionContext(context)
		M.process(context)
	end)
end

return M
