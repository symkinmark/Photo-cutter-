--[[----------------------------------------------------------------------------
HFSDetect.lua
Half-Frame Splitter - finding the dark dividing line and computing the crops.

No Lightroom dependencies (unit tested with plain Lua 5.1).

Coordinates: all positions returned here are normalised to 0..1 in the frame
of the analysed image (x to the right, y downwards).

How the detection works
  A half-frame pair scan holds two portrait frames side by side, separated by a
  strip of unexposed film that scans as a black (or very dark) band running
  across the whole short side of the image. For every column (or row) we know
  the brightness histogram, so we take the brightness that 90% of its pixels
  stay below (the "P90"). For a column inside the dividing band, P90 is very
  low, because nearly the whole column is black. Picture content - even a
  night scene - almost never has a column that is black from top to bottom.
  We look for the darkest such band in the middle part of the image, measure
  how clearly it stands out, and widen it to the exact band edges.
------------------------------------------------------------------------------]]

local M = {}

local floor, ceil, abs, max, min = math.floor, math.ceil, math.abs, math.max, math.min

-- Tunables (shared with the unit tests).
M.params = {
	searchFrom = 0.20,       -- look for the line between 20% ...
	searchTo = 0.80,         -- ... and 80% of the long side
	confidentFrom = 0.30,    -- a confident line lies between 30% ...
	confidentTo = 0.70,      -- ... and 70% of the long side
	minContrast = 24,        -- line must be this much darker than the content (0..255)
	maxGapLevel = 90,        -- line itself must be darker than this (0..255)
	minWidth = 0.003,        -- narrowest accepted line (fraction of long side)
	maxWidth = 0.15,         -- widest accepted line
	edgeExpand = 0.015,      -- max widening of the line at each edge
	ambiguity = 0.20,        -- a second line within 20% of the contrast is "ambiguous"
	borderMax = 0.12,        -- outer black borders: at most 12% per side
	squareTolerance = 1.15,  -- aspect ratios closer to 1 than this: try both directions
}

--------------------------------------------------------------------------------
-- Profiles

--- Returns an array (1..n) with the brightness (0..255) below which fraction
-- `p` of the pixels of each column/row lies.
function M.percentileProfile(hist, n, bins, p)
	local out = {}
	local binWidth = 256 / bins
	for i = 0, n - 1 do
		local base = i * bins
		local total = 0
		for b = 1, bins do total = total + hist[base + b] end
		local target = p * total
		local acc, val = 0, bins
		for b = 1, bins do
			acc = acc + hist[base + b]
			if acc >= target then
				val = b
				break
			end
		end
		out[i + 1] = (val - 0.5) * binWidth
	end
	return out
end

local function smooth(arr, radius)
	if radius < 1 then return arr end
	local n = #arr
	local out = {}
	for i = 1, n do
		local s, c = 0, 0
		for j = max(1, i - radius), min(n, i + radius) do
			s = s + arr[j]
			c = c + 1
		end
		out[i] = s / c
	end
	return out
end

--------------------------------------------------------------------------------
-- Line detection along one axis

--- Looks for the dividing line in a profile.
-- p90, p50: arrays 1..n. Returns a result table (see fields below).
--
-- The picture on each side of the line is measured separately: unexposed film
-- between frames has the same density as the deepest shadows of a picture, so
-- when one frame is very dark its side of the line cannot be seen. The edge
-- towards the brighter frame is still exact, and is used for a best guess.
function M.detectLine(p90, p50, n)
	local P = M.params
	local res = { found = false, confident = false, reasons = {} }

	local sm = smooth(p90, max(1, floor(n / 600)))

	local lo = max(1, floor(n * P.searchFrom) + 1)
	local hi = min(n, ceil(n * P.searchTo))
	local centre = (n + 1) / 2

	-- Darkest position in the search window (ties: closest to the centre).
	local gmin, gpos = math.huge, nil
	for i = lo, hi do
		local v = sm[i]
		if v < gmin - 1e-9 or (abs(v - gmin) <= 1e-9 and abs(i - centre) < abs(gpos - centre)) then
			gmin, gpos = v, i
		end
	end
	if not gpos then
		res.reasons[#res.reasons + 1] = 'no dark dividing line found'
		return res
	end
	res.lineLevel = gmin

	-- Brightness of the picture on each side (75th percentile of the profile,
	-- ignoring the outer 5% where film borders may be).
	local margin = max(1, floor(n * 0.01))
	local outer = floor(n * 0.05)
	local function sideLevel(a, b)
		a, b = max(1, a), min(n, b)
		if b - a < 3 then return gmin end
		local vals = {}
		for j = a, b do vals[#vals + 1] = sm[j] end
		table.sort(vals)
		return vals[max(1, floor(#vals * 0.75))]
	end
	local levelL = sideLevel(outer + 1, gpos - margin)
	local levelR = sideLevel(gpos + margin, n - outer)
	local contrastL, contrastR = levelL - gmin, levelR - gmin
	local contrast = min(contrastL, contrastR)
	res.content = min(levelL, levelR)
	res.contrast = contrast
	res.contrastLeft, res.contrastRight = contrastL, contrastR

	if max(contrastL, contrastR) <= 4 then
		res.reasons[#res.reasons + 1] = 'no dark dividing line found'
		return res
	end

	-- Core of the band: P90 below the halfway level towards each side.
	local tL = gmin + 0.5 * contrastL
	local tR = gmin + 0.5 * contrastR
	local s, e = gpos, gpos
	while s > 1 and sm[s - 1] <= tL do s = s - 1 end
	while e < n and sm[e + 1] <= tR do e = e + 1 end

	-- Widen to the real band edges: a column still belongs to the band while
	-- most of its pixels (P50) are nearly as dark as the line. This catches
	-- the partly covered columns at the edges of a slightly skewed scan.
	local eL = gmin + 0.3 * contrastL
	local eR = gmin + 0.3 * contrastR
	local maxExpand = max(1, floor(n * P.edgeExpand))
	local k = 0
	while s > 1 and k < maxExpand and p50[s - 1] <= eL do
		s = s - 1
		k = k + 1
	end
	k = 0
	while e < n and k < maxExpand and p50[e + 1] <= eR do
		e = e + 1
		k = k + 1
	end

	-- If one side is too dark to see, anchor the guess at the visible edge.
	local maxGuess = max(2, floor(n * 0.04))
	local oneSided = false
	if contrastL < P.minContrast and contrastR >= P.minContrast and e - s + 1 > maxGuess then
		s = e - maxGuess + 1
		oneSided = true
	elseif contrastR < P.minContrast and contrastL >= P.minContrast and e - s + 1 > maxGuess then
		e = s + maxGuess - 1
		oneSided = true
	end

	res.found = true
	res.startIndex, res.endIndex = s, e
	res.gapStart = (s - 1) / n
	res.gapEnd = e / n
	local width = (e - s + 1) / n
	local centrePos = (res.gapStart + res.gapEnd) / 2
	res.width, res.position = width, centrePos

	-- Plausibility checks.
	local ok = true
	local function fail(msg)
		ok = false
		res.reasons[#res.reasons + 1] = msg
	end

	if contrast < P.minContrast then
		if max(contrastL, contrastR) >= P.minContrast then
			fail('one picture is too dark next to the dividing line to see where it starts')
		else
			fail(string.format('dividing line is faint (contrast %d of 255)', floor(contrast + 0.5)))
		end
	end
	if gmin > P.maxGapLevel then
		fail(string.format('dividing line is not dark enough (level %d of 255)', floor(gmin + 0.5)))
	end
	if width < P.minWidth or (e - s + 1) < 2 then
		fail('dividing line is too thin to be sure')
	elseif width > P.maxWidth and not oneSided then
		fail(string.format('dark band is too wide (%.0f%% of the image, blank frame?)', width * 100))
	end
	if centrePos < P.confidentFrom or centrePos > P.confidentTo then
		fail(string.format('dividing line is far from the centre (at %.0f%%)', centrePos * 100))
	end

	-- Another, similarly dark line elsewhere in the middle part of the image?
	if ok then
		local tSimilar = gmin + P.ambiguity * contrast
		local minW = max(2, floor(n * P.minWidth))
		local i = max(1, floor(n * 0.10))
		local last = min(n, ceil(n * 0.90))
		while i <= last do
			if (i < s or i > e) and sm[i] <= tSimilar then
				local a = i
				while i + 1 <= last and (i + 1 < s or i + 1 > e) and sm[i + 1] <= tSimilar do i = i + 1 end
				if i - a + 1 >= minW then
					fail('several similar dark lines found')
					break
				end
			end
			i = i + 1
		end
	end

	res.confident = ok
	-- A usable guess even when not fully confident.
	res.usableGuess = width >= P.minWidth and width <= P.maxWidth
		and centrePos >= 0.25 and centrePos <= 0.75
		and max(contrastL, contrastR) >= P.minContrast
	return res
end

-- Number of positions from one end of a profile that are at or below t.
local function edgeRun(profile, fromStart, t, limit)
	local n = #profile
	local count = 0
	while count < limit do
		local idx = fromStart and (count + 1) or (n - count)
		if idx < 1 or idx > n or profile[idx] > t then break end
		count = count + 1
	end
	return count
end

--------------------------------------------------------------------------------
-- Full analysis

--- Analyses histograms produced by HFSImage.decodeBMPHistograms.
-- opts.trimBorders: also measure black outer borders.
-- Returns a detection table with:
--   axis ('x' = vertical line, picture split left/right; 'y' = horizontal line)
--   found, confident, usableGuess, gapStart, gapEnd, reasons (array of strings)
--   borders = { along0, along1, cross0, cross1 } (fractions, only if trimBorders)
function M.analyze(img, opts)
	opts = opts or {}
	local P = M.params
	local W, H, B = img.width, img.height, img.bins

	local colP90 = M.percentileProfile(img.colHist, W, B, 0.9)
	local colP75 = M.percentileProfile(img.colHist, W, B, 0.75)
	local colP50 = M.percentileProfile(img.colHist, W, B, 0.5)
	local rowP90 = M.percentileProfile(img.rowHist, H, B, 0.9)
	local rowP75 = M.percentileProfile(img.rowHist, H, B, 0.75)
	local rowP50 = M.percentileProfile(img.rowHist, H, B, 0.5)

	local axes
	if W >= H * P.squareTolerance then
		axes = { 'x' }
	elseif H >= W * P.squareTolerance then
		axes = { 'y' }
	else
		axes = { 'x', 'y' }
	end

	-- P90 copes best with dark pictures; P75 still finds a line that is partly
	-- fogged by a light leak (common with half-frame cameras).
	local function rank(d)
		return (d.confident and 2 or 0) + (d.found and 1 or 0)
	end
	local best
	for _, axis in ipairs(axes) do
		local tries
		if axis == 'x' then
			tries = { { colP90, colP50, W }, { colP75, colP50, W } }
		else
			tries = { { rowP90, rowP50, H }, { rowP75, rowP50, H } }
		end
		for _, t in ipairs(tries) do
			local r = M.detectLine(t[1], t[2], t[3])
			r.axis = axis
			if not best or rank(r) > rank(best)
				or (rank(r) == rank(best) and (r.contrast or 0) > (best.contrast or 0)) then
				best = r
			end
		end
	end

	best.width, best.height = W, H
	best.borders = { along0 = 0, along1 = 0, cross0 = 0, cross1 = 0 }

	if opts.trimBorders and best.found then
		local along = best.axis == 'x' and colP90 or rowP90
		local cross = best.axis == 'x' and rowP90 or colP90
		local sa = smooth(along, max(1, floor(#along / 600)))
		local sc = smooth(cross, max(1, floor(#cross / 600)))
		local t = best.lineLevel + 0.25 * best.contrast
		local na, nc = #along, #cross
		best.borders.along0 = edgeRun(sa, true, t, floor(na * P.borderMax)) / na
		best.borders.along1 = edgeRun(sa, false, t, floor(na * P.borderMax)) / na
		best.borders.cross0 = edgeRun(sc, true, t, floor(nc * P.borderMax)) / nc
		best.borders.cross1 = edgeRun(sc, false, t, floor(nc * P.borderMax)) / nc
	end

	return best
end

--------------------------------------------------------------------------------
-- Crops

local function rect(axis, a0, a1, c0, c1)
	if axis == 'x' then
		return { left = a0, right = a1, top = c0, bottom = c1 }
	end
	return { left = c0, right = c1, top = a0, bottom = a1 }
end

local function clamp01(v)
	if v < 0 then return 0 end
	if v > 1 then return 1 end
	return v
end

--- Computes the two crop rectangles (in the analysed frame) for a detection.
-- opts.extraTrimPercent: extra trim at the cut on each side (percent of the long side)
-- opts.useGuess: when the detection is not confident, use its best guess if it is usable
-- Returns rects (array of 2), method ('line', 'guess' or 'middle').
function M.computeCrops(det, opts)
	opts = opts or {}
	local trim = (opts.extraTrimPercent or 0) / 100
	local axis = det.axis
	if not axis then
		axis = (det.width or 1) >= (det.height or 1) and 'x' or 'y'
	end

	local g0, g1, method
	if det.found and det.confident then
		g0, g1, method = det.gapStart - trim, det.gapEnd + trim, 'line'
	elseif det.found and det.usableGuess and opts.useGuess ~= false then
		g0, g1, method = det.gapStart - trim, det.gapEnd + trim, 'guess'
	else
		g0, g1, method = 0.5, 0.5, 'middle'
	end

	local b = det.borders or {}
	local a0 = b.along0 or 0
	local a1 = 1 - (b.along1 or 0)
	local c0 = b.cross0 or 0
	local c1 = 1 - (b.cross1 or 0)
	if method == 'middle' then
		a0, a1, c0, c1 = 0, 1, 0, 1
	end

	-- Never let a half become tiny because of trims/borders.
	if g0 - a0 < 0.2 then a0 = 0 end
	if a1 - g1 < 0.2 then a1 = 1 end
	if c1 - c0 < 0.5 then c0, c1 = 0, 1 end

	return {
		rect(axis, clamp01(a0), clamp01(g0), clamp01(c0), clamp01(c1)),
		rect(axis, clamp01(g1), clamp01(a1), clamp01(c0), clamp01(c1)),
	}, method
end

--------------------------------------------------------------------------------
-- Orientation helpers

-- EXIF orientation: maps a point (u, v) in the displayed (oriented) image to
-- (x, y) in the stored pixel data. Both normalised to 0..1.
local exifDisplayToStored = {
	[1] = function(u, v) return u, v end,
	[2] = function(u, v) return 1 - u, v end,
	[3] = function(u, v) return 1 - u, 1 - v end,
	[4] = function(u, v) return u, 1 - v end,
	[5] = function(u, v) return v, u end,
	[6] = function(u, v) return v, 1 - u end,
	[7] = function(u, v) return 1 - v, 1 - u end,
	[8] = function(u, v) return 1 - v, u end,
}

local function mapRect(r, fn)
	local xs, ys = {}, {}
	local corners = { { r.left, r.top }, { r.right, r.top }, { r.left, r.bottom }, { r.right, r.bottom } }
	for i, c in ipairs(corners) do
		xs[i], ys[i] = fn(c[1], c[2])
	end
	return {
		left = min(xs[1], xs[2], xs[3], xs[4]),
		right = max(xs[1], xs[2], xs[3], xs[4]),
		top = min(ys[1], ys[2], ys[3], ys[4]),
		bottom = max(ys[1], ys[2], ys[3], ys[4]),
	}
end

--- Converts a rectangle measured on an EXIF-oriented image into the stored
-- pixel frame (the frame Lightroom's crop values use).
function M.exifRectToStored(r, orientation)
	local fn = exifDisplayToStored[orientation or 1] or exifDisplayToStored[1]
	return mapRect(r, fn)
end

-- Lightroom orientation codes: maps a point (x, y) in the stored ("AB") frame
-- to (u, v) as shown on screen.
local lrStoredToDisplay = {
	AB = function(x, y) return x, y end,
	BC = function(x, y) return 1 - y, x end,
	CD = function(x, y) return 1 - x, 1 - y end,
	DA = function(x, y) return y, 1 - x end,
}

--- Returns the two rectangles ordered as they appear on screen (left before
-- right, top before bottom), given Lightroom's orientation code.
function M.orderForDisplay(rects, lrOrientation)
	local fn = lrStoredToDisplay[lrOrientation or 'AB'] or lrStoredToDisplay.AB
	local c = {}
	for i, r in ipairs(rects) do
		local u, v = fn((r.left + r.right) / 2, (r.top + r.bottom) / 2)
		c[i] = { u = u, v = v }
	end
	local du, dv = c[2].u - c[1].u, c[2].v - c[1].v
	local swap
	if abs(du) >= abs(dv) then swap = du < 0 else swap = dv < 0 end
	if swap then return { rects[2], rects[1] } end
	return { rects[1], rects[2] }
end

-- Clockwise rotation (degrees) that turns the stored pixels into what
-- Lightroom shows, per Lightroom orientation code; and per EXIF orientation.
local lrDegrees = { AB = 0, BC = 90, CD = 180, DA = 270 }
local exifDegrees = { [3] = 180, [6] = 90, [8] = 270 }

--- Clockwise rotation that turns the analysed image the way Lightroom shows
-- the photo. exifApplied: the EXIF orientation that was already applied to
-- the analysed image (nil if none was).
function M.previewRotation(lrOrientation, exifApplied)
	local deg = lrDegrees[lrOrientation or 'AB'] or 0
	deg = deg - (exifDegrees[exifApplied or 1] or 0)
	return deg % 360
end

--- How a cut along `axis` of the analysed image looks on screen after
-- turning it by `rotation` degrees clockwise.
-- Returns fromLeft (true: position counts from the left, false: from the
-- top) and reversed (true: screen position = 1 - analysed position).
function M.displayDirection(axis, rotation)
	local upright = rotation == 0 or rotation == 180
	local fromLeft = (axis == 'x') == upright
	local reversed
	if axis == 'x' then
		reversed = rotation == 180 or rotation == 270
	else
		reversed = rotation == 90 or rotation == 180
	end
	return fromLeft, reversed
end

--- Crops for a cut at a chosen position (fraction along `axis` of the
-- analysed image).
function M.cropsAt(axis, position, borders, extraTrimPercent)
	return (M.computeCrops({
		axis = axis, found = true, confident = true,
		gapStart = position, gapEnd = position, borders = borders,
	}, { extraTrimPercent = extraTrimPercent }))
end

--- Lightroom develop settings for a crop rectangle in the stored frame.
function M.cropSettings(r)
	return {
		CropConstrainAspectRatio = false,
		CropAngle = 0,
		CropLeft = r.left,
		CropRight = r.right,
		CropTop = r.top,
		CropBottom = r.bottom,
	}
end

return M
