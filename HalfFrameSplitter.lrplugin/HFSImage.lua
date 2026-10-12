--[[----------------------------------------------------------------------------
HFSImage.lua
Half-Frame Splitter - pure-Lua image helpers.

This file has no Lightroom dependencies so it can be unit tested with a plain
Lua 5.1 interpreter. It provides:

  * decodeBMPHistograms  - turns a BMP file (as written by macOS `sips`) into
                           per-column and per-row brightness histograms
  * readOrientation      - reads the EXIF/TIFF orientation tag (1..8) from a
                           JPEG or TIFF file on disk
  * makeOrientationProbeJpeg / makeOrientationProbeTiff
                         - tiny images with orientation 6, used to find out
                           once whether `sips` applies the orientation tag
------------------------------------------------------------------------------]]

local M = {}

local floor = math.floor
local min = math.min
local byte = string.byte
local char = string.char
local unpack = unpack or table.unpack

-- Number of pixels decoded per string.byte call. Keeps the number of returned
-- values well below Lua's C-stack limit (8000 in Lua 5.1).
local CHUNK_PIXELS = 1000

--------------------------------------------------------------------------------
-- Little helpers for reading binary data (offsets are 0-based)

local function u16le(s, o)
	local a, b = byte(s, o + 1, o + 2)
	return a + b * 256
end

local function u32le(s, o)
	local a, b, c, d = byte(s, o + 1, o + 4)
	return a + b * 256 + c * 65536 + d * 16777216
end

local function s32le(s, o)
	local v = u32le(s, o)
	if v >= 2147483648 then v = v - 4294967296 end
	return v
end

local function u16be(s, o)
	local a, b = byte(s, o + 1, o + 2)
	return a * 256 + b
end

local function u32be(s, o)
	local a, b, c, d = byte(s, o + 1, o + 4)
	return a * 16777216 + b * 65536 + c * 256 + d
end

-- Describes a channel bit mask: returns shift, number of bits.
local function maskInfo(mask)
	if not mask or mask == 0 then return nil end
	local shift = 0
	while mask % 2 == 0 do
		mask = mask / 2
		shift = shift + 1
	end
	local bits = 0
	while mask % 2 == 1 do
		mask = (mask - 1) / 2
		bits = bits + 1
	end
	return shift, bits
end

--------------------------------------------------------------------------------
-- BMP decoding

--- Lookup table: (R + 2G + B) in 0..1020 -> 1-based histogram bin.
local lutCache = {}
local function binLookup(bins)
	local lut = lutCache[bins]
	if lut then return lut end
	lut = {}
	for s = 0, 1020 do
		local b = floor(s * bins / 1024) + 1
		if b > bins then b = bins end
		lut[s + 1] = b
	end
	lutCache[bins] = lut
	return lut
end

--- Parses the BMP header. Returns a header table or nil, error message.
function M.parseBMPHeader(data)
	if type(data) ~= 'string' or #data < 26 or data:sub(1, 2) ~= 'BM' then
		return nil, 'not a BMP file'
	end
	local h = {}
	h.dataOffset = u32le(data, 10)
	h.headerSize = u32le(data, 14)
	local paletteStart, paletteEntrySize
	if h.headerSize == 12 then
		-- OS/2 BITMAPCOREHEADER
		h.width = u16le(data, 18)
		h.height = u16le(data, 20)
		h.topDown = false
		h.bpp = u16le(data, 24)
		h.compression = 0
		h.colorsUsed = 0
		paletteStart = 14 + 12
		paletteEntrySize = 3
	elseif h.headerSize >= 40 then
		if #data < 54 then return nil, 'truncated BMP header' end
		h.width = s32le(data, 18)
		local height = s32le(data, 22)
		h.topDown = height < 0
		h.height = height < 0 and -height or height
		h.bpp = u16le(data, 28)
		h.compression = u32le(data, 30)
		h.colorsUsed = u32le(data, 46)
		paletteStart = 14 + h.headerSize
		paletteEntrySize = 4
		if h.compression == 3 or h.compression == 6 then
			-- Channel masks live at file offset 54 (inside V2+ headers, or
			-- directly after a 40-byte header).
			if #data < 66 then return nil, 'truncated BMP masks' end
			h.redMask = u32le(data, 54)
			h.greenMask = u32le(data, 58)
			h.blueMask = u32le(data, 62)
			if h.headerSize == 40 then
				paletteStart = paletteStart + (h.compression == 6 and 16 or 12)
			end
		end
	else
		return nil, 'unsupported BMP header size ' .. tostring(h.headerSize)
	end

	if h.width <= 0 or h.height <= 0 then return nil, 'invalid BMP size' end
	if h.compression ~= 0 and h.compression ~= 3 and h.compression ~= 6 then
		return nil, 'compressed BMP files are not supported (compression ' .. h.compression .. ')'
	end
	local bpp = h.bpp
	if bpp ~= 1 and bpp ~= 4 and bpp ~= 8 and bpp ~= 16 and bpp ~= 24 and bpp ~= 32 then
		return nil, 'unsupported BMP bit depth ' .. tostring(bpp)
	end

	if bpp <= 8 then
		local count = h.colorsUsed
		if count == 0 then count = 2 ^ bpp end
		h.palette = {}    -- index -> R + 2G + B
		h.paletteBGR = {} -- index -> 3-byte string B, G, R
		for i = 0, count - 1 do
			local o = paletteStart + i * paletteEntrySize
			if o + 3 > #data then break end
			local b, g, r = byte(data, o + 1, o + 3)
			h.palette[i] = r + 2 * g + b
			h.paletteBGR[i] = char(b, g, r)
		end
	end

	if bpp == 16 and h.compression == 0 then
		h.redMask, h.greenMask, h.blueMask = 0x7C00, 0x03E0, 0x001F
	elseif bpp == 32 and h.compression == 0 then
		h.redMask, h.greenMask, h.blueMask = 0x00FF0000, 0x0000FF00, 0x000000FF
	end

	h.stride = floor((bpp * h.width + 31) / 32) * 4
	if #data < h.dataOffset + h.stride * (h.height - 1) + floor((bpp * h.width + 7) / 8) then
		return nil, 'BMP pixel data is truncated'
	end
	return h
end

--- Decodes a BMP into brightness histograms.
-- Returns a table:
--   width, height, bins
--   colHist: flat array, colHist[x * bins + b] = pixel count of column x (0-based) in bin b (1-based)
--   rowHist: same for rows
-- or nil, error message.
function M.decodeBMPHistograms(data, bins)
	bins = bins or 32
	local h, err = M.parseBMPHeader(data)
	if not h then return nil, err end

	local W, H, B = h.width, h.height, bins
	local lut = binLookup(B)
	local colHist, rowHist = {}, {}
	for i = 1, W * B do colHist[i] = 0 end
	for i = 1, H * B do rowHist[i] = 0 end

	local bpp = h.bpp
	local stride = h.stride
	local dataOffset = h.dataOffset

	-- Per-pixel "sum" (R + 2G + B, range 0..1020) for bit-field formats.
	local fastIdx -- byte indices of R, G, B inside a 32-bit pixel, if byte aligned
	local generic -- function(value) -> sum, for non byte-aligned masks
	if bpp == 16 or bpp == 32 then
		local rs, rb = maskInfo(h.redMask)
		local gs, gb = maskInfo(h.greenMask)
		local bs, bb = maskInfo(h.blueMask)
		if not (rs and gs and bs) then return nil, 'BMP has empty colour masks' end
		if bpp == 32 and rb == 8 and gb == 8 and bb == 8 and rs % 8 == 0 and gs % 8 == 0 and bs % 8 == 0 then
			fastIdx = { rs / 8, gs / 8, bs / 8 }
		else
			local rDiv, gDiv, bDiv = 2 ^ rs, 2 ^ gs, 2 ^ bs
			local rMod, gMod, bMod = 2 ^ rb, 2 ^ gb, 2 ^ bb
			local rScale, gScale, bScale = 255 / (rMod - 1), 255 / (gMod - 1), 255 / (bMod - 1)
			generic = function(v)
				local r = floor(v / rDiv) % rMod * rScale
				local g = floor(v / gDiv) % gMod * gScale
				local b = floor(v / bDiv) % bMod * bScale
				return floor(r + 2 * g + b + 0.5)
			end
		end
	end

	local palette = h.palette

	for r = 0, H - 1 do
		local y = h.topDown and r or (H - 1 - r)
		local rowBase = y * B
		local p = dataOffset + r * stride + 1 -- 1-based string index of the row
		local x = 0

		if bpp == 24 then
			while x < W do
				local n = min(CHUNK_PIXELS, W - x)
				local t = { byte(data, p, p + n * 3 - 1) }
				local k = 1
				for _ = 1, n do
					local b = lut[t[k] + 2 * t[k + 1] + t[k + 2] + 1]
					local ci = x * B + b
					colHist[ci] = colHist[ci] + 1
					local ri = rowBase + b
					rowHist[ri] = rowHist[ri] + 1
					k = k + 3
					x = x + 1
				end
				p = p + n * 3
			end
		elseif bpp == 32 and fastIdx then
			local ri0, gi0, bi0 = fastIdx[1] + 1, fastIdx[2] + 1, fastIdx[3] + 1
			while x < W do
				local n = min(CHUNK_PIXELS, W - x)
				local t = { byte(data, p, p + n * 4 - 1) }
				local k = 0
				for _ = 1, n do
					local b = lut[t[k + ri0] + 2 * t[k + gi0] + t[k + bi0] + 1]
					local ci = x * B + b
					colHist[ci] = colHist[ci] + 1
					local ri = rowBase + b
					rowHist[ri] = rowHist[ri] + 1
					k = k + 4
					x = x + 1
				end
				p = p + n * 4
			end
		elseif bpp == 8 then
			while x < W do
				local n = min(CHUNK_PIXELS, W - x)
				local t = { byte(data, p, p + n - 1) }
				for k = 1, n do
					local b = lut[(palette[t[k]] or 0) + 1]
					local ci = x * B + b
					colHist[ci] = colHist[ci] + 1
					local ri = rowBase + b
					rowHist[ri] = rowHist[ri] + 1
					x = x + 1
				end
				p = p + n
			end
		else
			-- Slow generic path: 1, 4, 16 bpp and unusual 32 bpp masks.
			for xx = 0, W - 1 do
				local s
				if bpp == 1 or bpp == 4 then
					local bitPos = xx * bpp
					local v = byte(data, p + floor(bitPos / 8))
					local shift = 8 - bpp - (bitPos % 8)
					local idx = floor(v / 2 ^ shift) % 2 ^ bpp
					s = palette[idx] or 0
				elseif bpp == 16 then
					s = generic(u16le(data, p - 1 + xx * 2))
				else
					s = generic(u32le(data, p - 1 + xx * 4))
				end
				if s > 1020 then s = 1020 end
				local b = lut[s + 1]
				local ci = xx * B + b
				colHist[ci] = colHist[ci] + 1
				local ri = rowBase + b
				rowHist[ri] = rowHist[ri] + 1
			end
		end
	end

	return {
		width = W,
		height = H,
		bins = B,
		colHist = colHist,
		rowHist = rowHist,
	}
end

--------------------------------------------------------------------------------
-- Pixel rows (for the "where should I cut?" preview)

--- Decodes a BMP into 24-bit pixel rows.
-- Returns { width, height, rows } where rows[1] is the top row, each a string
-- of width * 3 bytes in B, G, R order; or nil, error message.
function M.decodeBMPRows(data)
	local h, err = M.parseBMPHeader(data)
	if not h then return nil, err end
	local W, H, bpp = h.width, h.height, h.bpp

	-- Per-pixel reader for everything except 24 bpp: returns B, G, R.
	local readPixel
	if bpp == 16 or bpp == 32 then
		local rs, rb = maskInfo(h.redMask)
		local gs, gb = maskInfo(h.greenMask)
		local bs, bb = maskInfo(h.blueMask)
		if not (rs and gs and bs) then return nil, 'BMP has empty colour masks' end
		local function channel(v, shift, bits)
			return floor(floor(v / 2 ^ shift) % 2 ^ bits * 255 / (2 ^ bits - 1) + 0.5)
		end
		local readValue = bpp == 16 and u16le or u32le
		local size = bpp / 8
		readPixel = function(rowOffset, x)
			local v = readValue(data, rowOffset + x * size)
			return channel(v, bs, bb), channel(v, gs, gb), channel(v, rs, rb)
		end
	elseif bpp <= 8 then
		local black = char(0, 0, 0)
		readPixel = function(rowOffset, x)
			local bitPos = x * bpp
			local v = byte(data, rowOffset + floor(bitPos / 8) + 1)
			local idx = floor(v / 2 ^ (8 - bpp - bitPos % 8)) % 2 ^ bpp
			return byte(h.paletteBGR[idx] or black, 1, 3)
		end
	end

	local rows = {}
	for r = 0, H - 1 do
		local y = h.topDown and r or (H - 1 - r)
		local rowOffset = h.dataOffset + r * h.stride -- 0-based
		local row
		if bpp == 24 then
			row = data:sub(rowOffset + 1, rowOffset + W * 3)
		else
			local parts = {}
			local x = 0
			while x < W do
				local n = min(CHUNK_PIXELS, W - x)
				local t = {}
				for i = 0, n - 1 do
					local b, g, rr = readPixel(rowOffset, x + i)
					t[#t + 1] = b
					t[#t + 1] = g
					t[#t + 1] = rr
				end
				parts[#parts + 1] = char(unpack(t))
				x = x + n
			end
			row = table.concat(parts)
		end
		rows[y + 1] = row
	end
	return { width = W, height = H, rows = rows }
end

--- Encodes 24-bit pixel rows (as returned by decodeBMPRows) as a BMP file.
function M.encodeBMP24(img)
	local W, H = img.width, img.height
	local stride = floor((24 * W + 31) / 32) * 4
	local pad = string.rep('\0', stride - W * 3)
	local imageSize = stride * H
	local function le16(n) return char(n % 256, floor(n / 256) % 256) end
	local function le32(n)
		return char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
	end
	local parts = {
		'BM', le32(54 + imageSize), le32(0), le32(54),
		le32(40), le32(W), le32(H), le16(1), le16(24), le32(0), le32(imageSize),
		le32(2835), le32(2835), le32(0), le32(0),
	}
	for y = H, 1, -1 do -- BMP rows run bottom-up
		parts[#parts + 1] = img.rows[y]
		parts[#parts + 1] = pad
	end
	return table.concat(parts)
end

--- Returns a copy of the image with lines drawn across it.
-- axis 'x': vertical lines at the given fractions of the width;
-- axis 'y': horizontal lines at fractions of the height.
-- color: { r, g, b }; thickness in pixels.
function M.drawLines(img, axis, positions, color, thickness)
	local W, H = img.width, img.height
	local px = char(color[3], color[2], color[1])
	thickness = thickness or 2
	local rows = {}
	for y = 1, H do rows[y] = img.rows[y] end
	local n = axis == 'x' and W or H
	for _, pos in ipairs(positions) do
		local c0 = floor(pos * n - thickness / 2 + 0.5)
		if c0 < 0 then c0 = 0 end
		if c0 > n - thickness then c0 = n - thickness end
		local c1 = c0 + thickness -- exclusive, 0-based
		if axis == 'x' then
			local seg = string.rep(px, c1 - c0)
			for y = 1, H do
				local row = rows[y]
				rows[y] = row:sub(1, c0 * 3) .. seg .. row:sub(c1 * 3 + 1)
			end
		else
			local full = string.rep(px, W)
			for y = c0 + 1, c1 do rows[y] = full end
		end
	end
	return { width = W, height = H, rows = rows }
end

--------------------------------------------------------------------------------
-- Orientation tag reading (EXIF in JPEG, IFD0 in TIFF)

local function readAt(f, offset, n)
	if not f:seek('set', offset) then return nil end
	local s = f:read(n)
	if not s or #s < n then return nil end
	return s
end

-- Reads tag 274 (Orientation) from a TIFF structure that starts at `base`
-- within file `f`.
local function orientationFromTiff(f, base)
	local hdr = readAt(f, base, 8)
	if not hdr then return nil end
	local u16, u32
	local order = hdr:sub(1, 2)
	if order == 'II' then
		u16, u32 = u16le, u32le
	elseif order == 'MM' then
		u16, u32 = u16be, u32be
	else
		return nil
	end
	if u16(hdr, 2) ~= 42 then return nil end -- BigTIFF etc. not handled
	local ifd = u32(hdr, 4)
	local countStr = readAt(f, base + ifd, 2)
	if not countStr then return nil end
	local count = u16(countStr, 0)
	if count == 0 or count > 1000 then return nil end
	local entries = readAt(f, base + ifd + 2, count * 12)
	if not entries then return nil end
	for i = 0, count - 1 do
		local o = i * 12
		if u16(entries, o) == 274 then
			local value = u16(entries, o + 8) -- SHORT, left-justified in the value field
			if value >= 1 and value <= 8 then return value end
			return nil
		end
	end
	return nil
end

local function orientationFromJpeg(f)
	local pos = 2
	for _ = 1, 64 do
		local m = readAt(f, pos, 4)
		if not m or byte(m, 1) ~= 0xFF then return nil end
		local marker = byte(m, 2)
		if marker == 0xD9 or marker == 0xDA then return nil end -- end of image / start of scan
		local len = u16be(m, 2)
		if marker == 0xE1 then
			local id = readAt(f, pos + 4, 6)
			if id == 'Exif\0\0' then
				return orientationFromTiff(f, pos + 10)
			end
		end
		pos = pos + 2 + len
	end
	return nil
end

--- Returns the EXIF/TIFF orientation (1..8) of a JPEG or TIFF file (nil if
-- it has none), and the file kind: 'jpeg', 'tiff' or nil for other files.
function M.readOrientation(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local kind
	local ok, result = pcall(function()
		local magic = f:read(4)
		if not magic or #magic < 4 then return nil end
		if byte(magic, 1) == 0xFF and byte(magic, 2) == 0xD8 then
			kind = 'jpeg'
			return orientationFromJpeg(f)
		elseif magic == 'II*\0' or magic == 'MM\0*' then
			kind = 'tiff'
			return orientationFromTiff(f, 0)
		end
		return nil
	end)
	f:close()
	if ok then return result, kind end
	return nil, kind
end

--------------------------------------------------------------------------------
-- Orientation probes: tiny images tagged with orientation 6 ("rotate 90
-- degrees clockwise to display"). If a converter honours the tag, a probe
-- that is wider than tall comes out taller than wide. JPEG and TIFF are
-- probed separately because decoders do not always treat them alike.

local function le16(n)
	return char(n % 256, floor(n / 256) % 256)
end

local function le32(n)
	return char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
end

--- 2x1 pixel greyscale TIFF with orientation 6.
function M.makeOrientationProbeTiff()
	local entries = {
		{ 256, 3, 2 },   -- ImageWidth
		{ 257, 3, 1 },   -- ImageLength
		{ 258, 3, 8 },   -- BitsPerSample
		{ 259, 3, 1 },   -- Compression: none
		{ 262, 3, 1 },   -- PhotometricInterpretation: BlackIsZero
		{ 273, 4, 0 },   -- StripOffsets (filled below)
		{ 274, 3, 6 },   -- Orientation
		{ 277, 3, 1 },   -- SamplesPerPixel
		{ 278, 3, 1 },   -- RowsPerStrip
		{ 279, 4, 2 },   -- StripByteCounts
	}
	local ifdSize = 2 + #entries * 12 + 4
	local dataOffset = 8 + ifdSize
	entries[6][3] = dataOffset
	local parts = { 'II', le16(42), le32(8), le16(#entries) }
	for _, e in ipairs(entries) do
		local value = e[2] == 3 and (le16(e[3]) .. '\0\0') or le32(e[3])
		parts[#parts + 1] = le16(e[1]) .. le16(e[2]) .. le32(1) .. value
	end
	parts[#parts + 1] = le32(0)
	parts[#parts + 1] = char(0, 255)
	return table.concat(parts)
end

--- 16x8 pixel greyscale JPEG with EXIF orientation 6 (made with Pillow).
local PROBE_JPEG = table.concat {
	'\255\216\255\224\0\16\74\70\73\70\0\1\1\0\0\1\0\1\0\0\255\225\0\34\69\120\105\102\0\0\77\77',
	'\0\42\0\0\0\8\0\1\1\18\0\3\0\0\0\1\0\6\0\0\0\0\0\0\255\219\0\67\0\16\11\12',
	'\14\12\10\16\14\13\14\18\17\16\19\24\40\26\24\22\22\24\49\35\37\29\40\58\51\61\60\57\51\56\55\64',
	'\72\92\78\64\68\87\69\55\56\80\109\81\87\95\98\103\104\103\62\77\113\121\112\100\120\92\101\103\99\255\192\0',
	'\11\8\0\8\0\16\1\1\17\0\255\196\0\21\0\1\1\0\0\0\0\0\0\0\0\0\0\0\0\0\0\7',
	'\8\255\196\0\20\16\1\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\255\218\0\8\1\1\0\0\63',
	'\0\63\80\15\255\217',
}

function M.makeOrientationProbeJpeg()
	return PROBE_JPEG
end

return M
