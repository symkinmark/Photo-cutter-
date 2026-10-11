-- Unit tests for the pure-Lua parts of the plugin.
-- Run from the repository root:  lua5.1 tests/run_tests.lua
-- (fixtures are created by:      python3 tests/gen_fixtures.py)

local root = arg and arg[0] and arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/HalfFrameSplitter.lrplugin/?.lua;' .. package.path
local FIX = root .. '/tests/fixtures/'

local HFSImage = require 'HFSImage'
local HFSDetect = require 'HFSDetect'

local failures, passes = 0, 0
local function check(cond, msg)
	if cond then
		passes = passes + 1
	else
		failures = failures + 1
		print('FAIL: ' .. msg)
	end
end

local function readFile(p)
	local f = assert(io.open(p, 'rb'))
	local d = f:read('*a')
	f:close()
	return d
end

local manifest = dofile(FIX .. 'manifest.lua')
local opts = { extraTrimPercent = 0 }

-- Tolerance for the band edges: 0.6% of the long side (~7 px at 1200 px).
local TOL = 0.006

local function analyse(file, o)
	local img = assert(HFSImage.decodeBMPHistograms(readFile(FIX .. file), 32))
	return HFSDetect.analyze(img, o or opts), img
end

print('--- detection cases')
for _, c in ipairs(manifest.cases) do
	local t0 = os.clock()
	local det = analyse(c.file, { trimBorders = c.border > 0 })
	local dt = os.clock() - t0
	local info = string.format('%-11s axis=%s found=%s conf=%s gap=%.4f..%.4f (truth %.4f..%.4f) contrast=%.0f %.2fs %s',
		c.name, tostring(det.axis), tostring(det.found), tostring(det.confident),
		det.gapStart or -1, det.gapEnd or -1, c.gapStart, c.gapEnd, det.contrast or -1, dt,
		table.concat(det.reasons, '; '))
	print(info)
	if c.expect == 'confident' then
		check(det.confident, c.name .. ': expected a confident detection')
		check(det.axis == c.axis, c.name .. ': wrong axis')
		if det.found then
			-- The detected band must cover the black gap (allowing for blur at
			-- the edges) and must not eat noticeably into the pictures.
			check(math.abs(det.gapStart - c.gapStart) <= TOL, c.name .. ': gap start off')
			check(math.abs(det.gapEnd - c.gapEnd) <= TOL, c.name .. ': gap end off')
		end
	elseif c.expect == 'not_confident' then
		check(not det.confident, c.name .. ': expected NOT confident')
	elseif c.expect == 'guess_end' or c.expect == 'guess_start' then
		-- One frame is as dark as the gap: not confident, but the edge
		-- towards the bright frame must be exact so the guess is useful.
		check(not det.confident, c.name .. ': expected NOT confident')
		check(det.found and det.usableGuess, c.name .. ': expected a usable guess')
		if det.found then
			if c.expect == 'guess_end' then
				check(math.abs(det.gapEnd - c.gapEnd) <= TOL, c.name .. ': visible (right) edge off')
			else
				check(math.abs(det.gapStart - c.gapStart) <= TOL, c.name .. ': visible (left) edge off')
			end
		end
	end
	if c.border > 0 then
		local b = det.borders
		print(string.format('             borders along %.3f/%.3f cross %.3f/%.3f (truth %.3f)',
			b.along0, b.along1, b.cross0, b.cross1, c.border))
		check(math.abs(b.along0 - c.border) < 0.01 and math.abs(b.along1 - c.border) < 0.01,
			c.name .. ': along borders off')
		check(math.abs(b.cross0 - c.border) < 0.01 and math.abs(b.cross1 - c.border) < 0.01,
			c.name .. ': cross borders off')
	end
	check(dt < 3, c.name .. ': too slow')
end

print('--- BMP format variants')
for _, f in ipairs(manifest.formats) do
	local det = analyse(f.file)
	print(string.format('%-24s conf=%s gap=%.4f..%.4f', f.file, tostring(det.confident), det.gapStart or -1, det.gapEnd or -1))
	check(det.confident, f.file .. ': expected confident')
	check(det.found and math.abs(det.gapStart - f.gapStart) <= TOL, f.file .. ': gap start off')
	check(det.found and math.abs(det.gapEnd - f.gapEnd) <= TOL, f.file .. ': gap end off')
end
do
	local img, err = HFSImage.decodeBMPHistograms(readFile(FIX .. manifest.onebit), 32)
	check(img ~= nil, '1-bit BMP decodes: ' .. tostring(err))
	local h = HFSImage.parseBMPHeader(readFile(FIX .. 'fmt_v5_32_topdown.bmp'))
	check(h and h.topDown, 'top-down BMP recognised')
	check(HFSImage.decodeBMPHistograms('nonsense') == nil, 'garbage is rejected')
	local d = readFile(FIX .. 'basic.bmp')
	check(HFSImage.decodeBMPHistograms(d:sub(1, #d - 5000)) == nil, 'truncated BMP is rejected')
end

print('--- histogram totals')
do
	local img = assert(HFSImage.decodeBMPHistograms(readFile(FIX .. 'basic.bmp'), 32))
	local total = 0
	for i = 1, #img.colHist do total = total + img.colHist[i] end
	local total2 = 0
	for i = 1, #img.rowHist do total2 = total2 + img.rowHist[i] end
	check(total == img.width * img.height and total2 == total, 'histograms count every pixel once')
end

print('--- orientation tags')
for _, o in ipairs(manifest.orientation) do
	local v = HFSImage.readOrientation(FIX .. o.file)
	print(string.format('%-18s -> %s (expected %s)', o.file, tostring(v), tostring(o.value)))
	check(v == o.value, o.file .. ': orientation')
end
check(HFSImage.readOrientation(FIX .. 'basic.bmp') == nil, 'BMP has no orientation')
check(HFSImage.readOrientation(FIX .. 'does-not-exist.jpg') == nil, 'missing file -> nil')

print('--- orientation probes')
do
	local function writeProbe(name, data)
		local p = FIX .. name
		local f = assert(io.open(p, 'wb'))
		f:write(data)
		f:close()
		return p
	end
	local tif = writeProbe('probe.tif', HFSImage.makeOrientationProbeTiff())
	local jpg = writeProbe('probe.jpg', HFSImage.makeOrientationProbeJpeg())
	local o, kind = HFSImage.readOrientation(tif)
	check(o == 6 and kind == 'tiff', 'TIFF probe carries orientation 6')
	o, kind = HFSImage.readOrientation(jpg)
	check(o == 6 and kind == 'jpeg', 'JPEG probe carries orientation 6')
	-- Both must be valid images, wider than tall as stored.
	local p = io.popen('python3 -c "from PIL import Image; import sys\n'
		.. 'for f in sys.argv[1:]:\n im = Image.open(f); im.load(); print(im.size[0] > im.size[1])" '
		.. '"' .. tif .. '" "' .. jpg .. '" 2>&1')
	local out = p:read('*a')
	p:close()
	check(out == 'True\nTrue\n', 'probes decode: ' .. out)
	local _, k = HFSImage.readOrientation(FIX .. 'basic.bmp')
	check(k == nil, 'BMP kind is nil')
end

print('--- crop geometry')
do
	local det = { axis = 'x', found = true, confident = true, gapStart = 0.48, gapEnd = 0.52,
		borders = { along0 = 0, along1 = 0, cross0 = 0, cross1 = 0 } }
	local rects, method = HFSDetect.computeCrops(det, { extraTrimPercent = 0.5 })
	check(method == 'line', 'method line')
	check(math.abs(rects[1].right - 0.475) < 1e-9 and rects[1].left == 0, 'left half')
	check(math.abs(rects[2].left - 0.525) < 1e-9 and rects[2].right == 1, 'right half')
	check(rects[1].top == 0 and rects[1].bottom == 1, 'full height')

	det = { axis = 'y', found = true, confident = true, gapStart = 0.40, gapEnd = 0.43 }
	rects = HFSDetect.computeCrops(det, {})
	check(rects[1].top == 0 and math.abs(rects[1].bottom - 0.40) < 1e-9 and rects[1].left == 0 and rects[1].right == 1, 'top half')
	check(math.abs(rects[2].top - 0.43) < 1e-9 and rects[2].bottom == 1, 'bottom half')

	det = { found = false, confident = false, width = 1200, height = 800, axis = 'x' }
	rects, method = HFSDetect.computeCrops(det, { extraTrimPercent = 1 })
	check(method == 'middle' and rects[1].right == 0.5 and rects[2].left == 0.5, 'middle fallback')

	det = { axis = 'x', found = true, confident = false, usableGuess = true, gapStart = 0.45, gapEnd = 0.48 }
	rects, method = HFSDetect.computeCrops(det, {})
	check(method == 'guess' and rects[1].right == 0.45, 'best guess used')
	rects, method = HFSDetect.computeCrops(det, { useGuess = false })
	check(method == 'middle', 'best guess can be disabled')

	local s = HFSDetect.cropSettings(rects[1])
	check(s.CropLeft == rects[1].left and s.CropAngle == 0 and s.CropConstrainAspectRatio == false, 'crop settings')
end

print('--- orientation mapping')
do
	local function near(a, b) return math.abs(a - b) < 1e-9 end
	local function rectEq(a, b)
		return near(a.left, b.left) and near(a.right, b.right) and near(a.top, b.top) and near(a.bottom, b.bottom)
	end
	-- Left 40% of a displayed image with EXIF orientation 6 (stored image is
	-- rotated 90 deg CCW relative to the display): displayed left strip
	-- corresponds to the stored bottom strip.
	local r = HFSDetect.exifRectToStored({ left = 0, right = 0.4, top = 0, bottom = 1 }, 6)
	check(rectEq(r, { left = 0, right = 1, top = 0.6, bottom = 1 }), 'exif 6 mapping')
	r = HFSDetect.exifRectToStored({ left = 0, right = 0.4, top = 0, bottom = 1 }, 8)
	check(rectEq(r, { left = 0, right = 1, top = 0, bottom = 0.4 }), 'exif 8 mapping')
	r = HFSDetect.exifRectToStored({ left = 0, right = 0.4, top = 0.1, bottom = 0.9 }, 3)
	check(rectEq(r, { left = 0.6, right = 1, top = 0.1, bottom = 0.9 }), 'exif 3 mapping')
	r = HFSDetect.exifRectToStored({ left = 0.1, right = 0.4, top = 0.2, bottom = 0.7 }, 1)
	check(rectEq(r, { left = 0.1, right = 0.4, top = 0.2, bottom = 0.7 }), 'exif 1 identity')

	-- Cross-check the EXIF 6 mapping against Pillow's own exif_transpose
	-- semantics by a pixel round trip: stored pixel (x,y) shows at display
	-- (1-y, x); mapping back must return (x,y).
	local A = { left = 0.25, right = 0.25, top = 0.75, bottom = 0.75 }
	r = HFSDetect.exifRectToStored({ left = 1 - 0.75, right = 1 - 0.75, top = 0.25, bottom = 0.25 }, 6)
	check(rectEq(r, A), 'exif 6 round trip')

	local L = { left = 0, right = 0.48, top = 0, bottom = 1 }
	local R = { left = 0.52, right = 1, top = 0, bottom = 1 }
	local o = HFSDetect.orderForDisplay({ R, L }, 'AB')
	check(o[1] == L, 'AB: left first')
	o = HFSDetect.orderForDisplay({ L, R }, 'CD')
	check(o[1] == R, 'CD (180 deg): stored right half is shown on the left')
	-- BC: rotated 90 deg clockwise for display: stored left half -> top
	o = HFSDetect.orderForDisplay({ R, L }, 'BC')
	check(o[1] == L, 'BC: stored left half shows on top')
	o = HFSDetect.orderForDisplay({ L, R }, 'DA')
	check(o[1] == R, 'DA: stored right half shows on top')
	o = HFSDetect.orderForDisplay({ L, R }, 'weird')
	check(o[1] == L, 'unknown code treated as AB')
end

print('--- version numbers')
do
	local info = dofile(root .. '/HalfFrameSplitter.lrplugin/Info.lua')
	local main = readFile(root .. '/HalfFrameSplitter.lrplugin/HFSMain.lua')
	local v = info.VERSION
	local display = string.format('%d.%d.%d', v.major, v.minor, v.revision)
	check(v.display == display, 'Info.lua VERSION.display matches its numbers')
	check(main:find("M.VERSION = '" .. display .. "'", 1, true) ~= nil, 'HFSMain.VERSION matches Info.lua')
	check(info.LrToolkitIdentifier == 'com.github.symkinmark.halfframesplitter', 'plugin id never changes')
end

print(string.format('\n%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
