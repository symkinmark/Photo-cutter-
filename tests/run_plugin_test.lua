-- End-to-end test of the plugin flow against a simulated Lightroom SDK and a
-- Pillow-based stand-in for macOS `sips`.
-- Run from the repository root:  lua5.1 tests/run_plugin_test.lua

local root = arg and arg[0] and arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/HalfFrameSplitter.lrplugin/?.lua;' .. root .. '/tests/?.lua;' .. package.path
local LrMock = require 'lr_mock'

local WORK = root .. '/tests/fixtures/flow'
local TEMP = WORK .. '/temp'
os.execute('mkdir -p "' .. TEMP .. '"')
if not io.open(WORK .. '/flow_manifest.lua') then
	assert(os.execute('python3 "' .. root .. '/tests/gen_flow_images.py" "' .. WORK .. '"') == 0)
end
local truth = dofile(WORK .. '/flow_manifest.lua')

local TOL = 0.007
local failures, passes = 0, 0
local function check(cond, msg)
	if cond then
		passes = passes + 1
	else
		failures = failures + 1
		print('  FAIL: ' .. msg)
	end
end

local function md5(path)
	local p = io.popen('md5sum "' .. path .. '" 2>/dev/null')
	local s = p:read('*a')
	p:close()
	return s:match('^%x+')
end

local function tempFiles()
	local p = io.popen('ls -A "' .. TEMP .. '"')
	local s = p:read('*a')
	p:close()
	return s
end

local function halvesOf(photo)
	local h = {}
	for _, vc in ipairs(photo.virtualCopies) do
		if vc.copyName == 'Half 1' then h[1] = vc elseif vc.copyName == 'Half 2' then h[2] = vc end
	end
	return h
end

local function near(a, b, tol) return math.abs(a - b) <= (tol or TOL) end

-- Checks the two crops of a split photo against the truth (stored frame).
-- first: 'A' if Half 1 should be the left/top part in stored pixels, 'B' otherwise.
local function checkSplit(label, photo, t, trim, first)
	local h = halvesOf(photo)
	check(h[1] and h[2], label .. ': has Half 1 and Half 2')
	if not (h[1] and h[2]) then return end
	check(#h[1].applied == 1 and #h[2].applied == 1, label .. ': one crop applied per half')
	local s1, s2 = h[1].applied[1].settings, h[2].applied[1].settings
	local A, B
	if first == 'A' then A, B = s1, s2 else A, B = s2, s1 end
	check(A.CropAngle == 0 and A.CropConstrainAspectRatio == false, label .. ': crop flags')
	local g0, g1 = t.gapStart - trim, t.gapEnd + trim
	if t.axis == 'x' then
		check(near(A.CropLeft, 0) and near(A.CropRight, g0) and near(A.CropTop, 0) and near(A.CropBottom, 1),
			string.format('%s: first part crop L%.4f R%.4f T%.4f B%.4f (want R %.4f)', label, A.CropLeft, A.CropRight, A.CropTop, A.CropBottom, g0))
		check(near(B.CropLeft, g1) and near(B.CropRight, 1) and near(B.CropTop, 0) and near(B.CropBottom, 1),
			string.format('%s: second part crop L%.4f R%.4f (want L %.4f)', label, B.CropLeft, B.CropRight, g1))
	else
		check(near(A.CropTop, 0) and near(A.CropBottom, g0) and near(A.CropLeft, 0) and near(A.CropRight, 1),
			string.format('%s: first part crop T%.4f B%.4f L%.4f R%.4f (want B %.4f)', label, A.CropTop, A.CropBottom, A.CropLeft, A.CropRight, g0))
		check(near(B.CropTop, g1) and near(B.CropBottom, 1) and near(B.CropLeft, 0) and near(B.CropRight, 1),
			string.format('%s: second part crop T%.4f B%.4f (want T %.4f)', label, B.CropTop, B.CropBottom, g1))
	end
	check(#photo.applied == 0, label .. ': original develop settings untouched')
end

local function buildStandard(state)
	local P = {}
	P.pair = state.newPhoto { path = WORK .. '/pair.jpg' }
	P.tif = state.newPhoto { path = WORK .. '/pair_lzw.tif', fileFormat = 'TIFF' }
	P.exif6 = state.newPhoto { path = WORK .. '/pair_exif6.jpg', developSettings = { orientation = 'BC' } }
	P.userRot = state.newPhoto { path = WORK .. '/pair_user_rotated.jpg', developSettings = { orientation = 'CD' } }
	P.night = state.newPhoto { path = WORK .. '/night.jpg' }
	P.onenight = state.newPhoto { path = WORK .. '/onenight.jpg' }
	P.broken = state.newPhoto { path = WORK .. '/not_an_image.jpg' }
	P.missing = state.newPhoto { path = WORK .. '/missing.jpg' }
	P.video = state.newPhoto { path = WORK .. '/pair.jpg', fileName = 'clip.mov', fileFormat = 'VIDEO' }
	P.already = state.newPhoto { path = WORK .. '/pair.jpg', fileName = 'already.jpg' }
	local old = state.newPhoto { path = WORK .. '/pair.jpg', isVirtualCopy = true, masterPhoto = P.already, copyName = 'Half 1' }
	P.already.virtualCopies = { old }
	P.aVC = state.newPhoto { path = WORK .. '/pair.jpg', fileName = 'pair.jpg (copy)', isVirtualCopy = true, masterPhoto = P.pair, copyName = 'Copy 1' }
	P.pair.virtualCopies = { P.aVC }
	local order = { P.pair, P.tif, P.exif6, P.userRot, P.night, P.onenight, P.broken, P.missing, P.video, P.already, P.aVC }
	return P, order
end

local REAL_FILES = { 'pair.jpg', 'pair_lzw.tif', 'pair_exif6.jpg', 'pair_user_rotated.jpg', 'night.jpg', 'onenight.jpg', 'hidden.jpg', 'not_an_image.jpg' }

local function run(label, opts, build, verify)
	print('--- ' .. label)
	for _, m in ipairs({ 'HFSMain', 'HFSImage', 'HFSDetect' }) do package.loaded[m] = nil end
	local state = LrMock.setup {
		tempDir = TEMP, prefs = opts.prefs, vcMode = opts.vcMode, dialogResult = opts.dialogResult,
		ignoreCopyName = opts.ignoreCopyName, answers = opts.answers,
	}
	state.cancelProgress = opts.cancelProgress
	local HFSMain = require 'HFSMain'
	HFSMain.SIPS = 'python3 "' .. root .. '/tests/fake_sips.py"'
	if opts.orient then HFSMain.SIPS = 'FAKE_SIPS_ORIENT=1 ' .. HFSMain.SIPS end

	local before = {}
	for _, f in ipairs(REAL_FILES) do before[f] = md5(WORK .. '/' .. f) end

	local P, order = build(state)
	state.selection = order
	local t0 = os.clock()
	local ok, err = pcall(HFSMain.run)
	check(ok, label .. ': run without Lua error: ' .. tostring(err))
	print(string.format('  (%.1fs cpu)', os.clock() - t0))

	for _, f in ipairs(REAL_FILES) do
		check(md5(WORK .. '/' .. f) == before[f], label .. ': ' .. f .. ' unchanged on disk')
	end
	check(tempFiles() == '', label .. ': temporary files cleaned up: ' .. tempFiles())
	for _, p in ipairs(state.deleted or {}) do
		check(p:match('/hfs%-[^/]*$') ~= nil, label .. ': only temp files deleted (' .. p .. ')')
	end
	local visible = {}
	for _, p in ipairs(order) do
		if not p.hidden then visible[#visible + 1] = p end
	end
	local sel = state.catalog:getTargetPhotos()
	check(#sel == #visible and sel[1] == visible[1], label .. ': selection restored')

	verify(state, P)
	if state.messages[#state.messages] then
		print('  summary: ' .. state.messages[#state.messages].message:gsub('\n', '\n           '))
	end
end

local function reviewSet(state)
	local c = state.collections['Half-Frame Splitter/Needs review']
	local set = {}
	if c then for _, p in ipairs(c.photos) do set[p] = true end end
	return set, c
end

local function verifyStandard(trim)
	return function(state, P)
		checkSplit('pair.jpg', P.pair, truth['pair.jpg'], trim, 'A')
		checkSplit('pair_lzw.tif', P.tif, truth['pair_lzw.tif'], trim, 'A')
		-- EXIF 6 / Lightroom 'BC': displayed left = stored bottom -> Half 1 is part B
		checkSplit('pair_exif6.jpg', P.exif6, truth['pair_exif6.jpg'], trim, 'B')
		-- user rotated 180 deg in Lightroom: displayed left = stored right
		checkSplit('pair_user_rotated.jpg', P.userRot, truth['pair_user_rotated.jpg'], trim, 'B')

		local h = halvesOf(P.night)
		check(h[1] and h[2], 'night: split (middle) for review')
		if h[1] then
			local s = h[1].applied[1].settings
			check(near(s.CropRight, 0.5, 1e-9), 'night: split exactly in the middle')
		end
		local hn = halvesOf(P.onenight)
		check(hn[1] and hn[2], 'onenight: split at best guess for review')
		if hn[2] then
			local t = truth['onenight.jpg']
			check(near(hn[2].applied[1].settings.CropLeft, t.gapEnd + trim), 'onenight: visible edge used')
		end

		local review, coll = reviewSet(state)
		check(coll ~= nil, 'review collection created')
		check(state.collectionSets['Half-Frame Splitter'] ~= nil, 'collection set created')
		check(h[1] and review[h[1]] and review[h[2]], 'night halves in review')
		check(hn[1] and review[hn[1]] and review[hn[2]], 'onenight halves in review')
		local n = 0
		for _ in pairs(review) do n = n + 1 end
		check(n == 4, 'review holds exactly the 4 uncertain halves (has ' .. n .. ')')

		for _, k in ipairs({ 'broken', 'missing', 'video', 'aVC' }) do
			check(#P[k].virtualCopies == 0, k .. ': no copies created')
		end
		check(#P.already.virtualCopies == 1, 'already split: nothing new created')
		check(#P.pair.virtualCopies == 3, 'pair.jpg: existing copy kept, two halves added')

		local msg = state.messages[#state.messages]
		check(msg and msg.message:find('Split 6 pairs into 12 halves', 1, true), 'summary counts')
		check(msg and msg.message:find('missing.jpg', 1, true) and msg.message:find('not_an_image.jpg', 1, true), 'summary lists problems')
		check(msg and msg.message:find('already.jpg: already split', 1, true), 'summary lists already split')
		check(msg and msg.style == 'warning', 'summary style warning when problems')
	end
end

local SPLIT = { fallback = 'split' }

run('standard run (sips keeps stored orientation)', { prefs = SPLIT }, buildStandard, verifyStandard(0.003))

run('sips applies EXIF orientation', { orient = true, prefs = SPLIT }, buildStandard, function(state, P)
	verifyStandard(0.003)(state, P)
	local probed = false
	for _, l in ipairs(state.log) do
		if l:find('orientation probe (jpeg)', 1, true) and l:find('applies orientation: true', 1, true) then probed = true end
	end
	check(probed, 'JPEG probe detected that sips applies the orientation')
end)

run('createVirtualCopies needs write access', { vcMode = 'inside', prefs = SPLIT }, buildStandard, verifyStandard(0.003))

run('fallback = skip, no extra trim', { prefs = { fallback = 'skip', extraTrim = 0 } }, buildStandard, function(state, P)
	checkSplit('pair.jpg', P.pair, truth['pair.jpg'], 0, 'A')
	check(#P.night.virtualCopies == 0, 'night: not split')
	check(#P.onenight.virtualCopies == 0, 'onenight: not split')
	local review = reviewSet(state)
	check(review[P.night] and review[P.onenight], 'originals in review')
	check(state.prefs.fallback == 'skip' and state.prefs.extraTrim == 0, 'prefs kept')
end)

run('a photo that cannot be selected', {}, function(state)
	local P = {}
	P.pair = state.newPhoto { path = WORK .. '/pair.jpg' }
	P.hidden = state.newPhoto { path = WORK .. '/hidden.jpg', hidden = true }
	return P, { P.pair, P.hidden }
end, function(state, P)
	checkSplit('pair.jpg', P.pair, truth['pair.jpg'], 0.003, 'A')
	check(#P.hidden.virtualCopies == 0, 'hidden: nothing created')
	local msg = state.messages[#state.messages]
	check(msg and msg.message:find('hidden.jpg: could not select it', 1, true), 'hidden reported')
end)

run('Lightroom ignores the copy name', { ignoreCopyName = true, prefs = SPLIT }, buildStandard, verifyStandard(0.003))

run('second copy fails', {}, function(state)
	local P = {}
	P.pair = state.newPhoto { path = WORK .. '/pair.jpg' }
	P.bad = state.newPhoto { path = WORK .. '/hidden.jpg', fileName = 'bad.jpg', failSecondCopy = true }
	return P, { P.bad, P.pair }
end, function(state, P)
	checkSplit('pair.jpg', P.pair, truth['pair.jpg'], 0.003, 'A')
	local h = halvesOf(P.bad)
	check(h[1] and not h[2], 'bad: only Half 1 exists')
	check(h[1] and #h[1].applied == 1, 'bad: the existing half is cropped anyway')
	local msg = state.messages[#state.messages]
	check(msg and msg.message:find('only "Half 1" was made', 1, true), 'partial result reported')
	check(msg and msg.message:find('Split 1 pair into', 1, true), 'only the good pair counted')
end)

-- Where is the red line in a preview JPEG? Returns the fraction from the
-- left of red columns and from the top of red rows (-1 if none).
local function redLine(path)
	local p = io.popen('python3 -c "import sys, numpy as np\nfrom PIL import Image\n'
		.. 'a = np.asarray(Image.open(sys.argv[1]).convert(\'RGB\')).astype(int)\n'
		.. 'red = (a[:,:,0] > 170) & (a[:,:,1] < 110) & (a[:,:,2] < 110)\n'
		.. 'c = np.where(red.mean(0) > 0.6)[0]; r = np.where(red.mean(1) > 0.6)[0]\n'
		.. 'print(c.mean() / a.shape[1] if len(c) else -1, r.mean() / a.shape[0] if len(r) else -1)" '
		.. '"' .. path .. '"')
	local out = p:read('*a')
	p:close()
	local x, y = out:match('^(%S+)%s+(%S+)')
	return tonumber(x), tonumber(y)
end

local function buildUnclear(state)
	local P = {}
	P.pair = state.newPhoto { path = WORK .. '/pair.jpg' }
	P.night = state.newPhoto { path = WORK .. '/night.jpg' }
	P.onenight = state.newPhoto { path = WORK .. '/onenight.jpg' }
	-- the same night scan, turned 180 degrees in Lightroom
	P.nightRot = state.newPhoto { path = WORK .. '/night.jpg', fileName = 'night_rotated.jpg',
		developSettings = { orientation = 'CD' } }
	return P, { P.pair, P.night, P.onenight, P.nightRot }
end

local seen = {}
run('ask: you choose where to cut', {
	answers = {
		function(props, args)
			-- night.jpg: no usable guess, so the line starts in the middle
			check(args.cancelVerb == 'Cancel all', 'question has "Cancel all"')
			check(props.position == 50, 'night: starts in the middle')
			local x = redLine(props.preview)
			check(x and math.abs(x - 0.5) < 0.01, 'night: red line drawn in the middle (' .. tostring(x) .. ')')
			seen[#seen + 1] = props.preview
			props.position = 40
			x = redLine(props.preview)
			check(x and math.abs(x - 0.4) < 0.01, 'night: red line follows the slider to 40% (' .. tostring(x) .. ')')
			seen[#seen + 1] = props.preview
			return 'ok'
		end,
		function(props)
			-- onenight.jpg: the guess is offered; keep it
			local t = truth['onenight.jpg']
			check(props.position ~= 50 and math.abs(props.position / 100 - (t.gapStart + t.gapEnd) / 2) < 0.03,
				'onenight: starts at the best guess (' .. tostring(props.position) .. ')')
			local x = redLine(props.preview)
			check(x and math.abs(x - props.position / 100) < 0.02, 'onenight: red lines at the guess')
			return 'ok'
		end,
		function(props)
			-- night_rotated.jpg is shown turned 180 degrees, like in Lightroom
			props.position = 30
			local x = redLine(props.preview)
			check(x and math.abs(x - 0.3) < 0.01, 'rotated: red line 30% from the left on screen (' .. tostring(x) .. ')')
			return 'ok'
		end,
	},
}, buildUnclear, function(state, P)
	check(state.questions == 3, 'asked about the 3 unclear scans only')
	for _, path in ipairs(seen) do
		check(io.open(path) == nil, 'preview file removed: ' .. path)
	end
	local trim = 0.003
	local h = halvesOf(P.night)
	check(h[1] and h[2], 'night: split')
	if h[1] then
		local s1, s2 = h[1].applied[1].settings, h[2].applied[1].settings
		check(near(s1.CropRight, 0.4 - trim, 1e-6) and near(s2.CropLeft, 0.4 + trim, 1e-6), 'night: cut at 40%')
	end
	checkSplit('onenight (kept guess)', P.onenight, {
		axis = 'x', gapStart = truth['onenight.jpg'].gapEnd - 0.04, gapEnd = truth['onenight.jpg'].gapEnd,
	}, trim, 'A')
	local hr = halvesOf(P.nightRot)
	check(hr[1] and hr[2], 'rotated: split')
	if hr[1] then
		-- 30% from the left on screen = 70% in the stored file; Half 1 is
		-- the part on the left of the screen = the stored right part.
		local s1 = hr[1].applied[1].settings
		check(near(s1.CropLeft, 0.7 + trim, 1e-6) and near(s1.CropRight, 1, 1e-9), 'rotated: Half 1 is the right part of the file, cut at 70%')
	end
	checkSplit('pair.jpg', P.pair, truth['pair.jpg'], trim, 'A')
	local review, coll = reviewSet(state)
	check(coll == nil, 'nothing needs review: you chose every cut')
	local msg = state.messages[#state.messages].message
	check(msg:find('Split 4 pairs', 1, true) and msg:find('3 of them were cut where you chose', 1, true), 'summary mentions your choices')
end)

run('ask: skip one, best guess for the rest', {
	answers = {
		function(props)
			props.choice = 'skip'
			props.rest = true
			return 'ok'
		end,
	},
}, buildUnclear, function(state, P)
	check(state.questions == 1, 'asked only once')
	check(#P.night.virtualCopies == 0, 'night: not cut')
	local review = reviewSet(state)
	check(review[P.night], 'night original in review')
	local h, hr = halvesOf(P.onenight), halvesOf(P.nightRot)
	check(h[1] and review[h[1]] and review[h[2]], 'onenight cut at the guess and in review')
	check(hr[1] and review[hr[1]] and review[hr[2]], 'rotated night cut in the middle and in review')
	checkSplit('pair.jpg', P.pair, truth['pair.jpg'], 0.003, 'A')
end)

run('ask: cancel all', {
	answers = { function() return 'cancel' end },
}, buildUnclear, function(state, P)
	check(#P.pair.virtualCopies == 0 and #P.night.virtualCopies == 0, 'nothing created')
	check(state.messages[1] and state.messages[1].message:find('Cancelled', 1, true), 'cancel message')
end)

run('dialog cancelled', { dialogResult = 'cancel' }, buildStandard, function(state, P)
	check(#P.tif.virtualCopies == 0 and #P.night.virtualCopies == 0, 'nothing created')
	check(#state.messages == 0, 'no message')
end)

run('progress cancelled', { cancelProgress = true }, buildStandard, function(state, P)
	check(#P.tif.virtualCopies == 0, 'nothing created')
	check(state.messages[1] and state.messages[1].message:find('Cancelled', 1, true), 'cancel message')
end)

print(string.format('\n%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
