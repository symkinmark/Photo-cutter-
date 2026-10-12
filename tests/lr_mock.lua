-- A small simulation of the parts of the Lightroom Classic SDK the plugin
-- uses, so the whole plugin flow can run under plain Lua 5.1.
--
-- It is strict where Lightroom is strict: develop settings and collections
-- can only be changed inside catalog:withWriteAccessDo, and (depending on
-- `vcMode`) createVirtualCopies must be called outside or inside it.

local M = {}

local function newPhoto(state, t)
	state.nextId = state.nextId + 1
	local p = {
		localIdentifier = state.nextId,
		path = t.path,
		fileName = t.fileName or (t.path and t.path:match('[^/]+$')) or 'virtual',
		fileFormat = t.fileFormat or 'JPG',
		isVirtualCopy = t.isVirtualCopy or false,
		masterPhoto = t.masterPhoto,
		copyName = t.copyName,
		virtualCopies = {},
		developSettings = t.developSettings or { orientation = 'AB' },
		applied = {},
		hidden = t.hidden or false,
		failSecondCopy = t.failSecondCopy or false,
	}
	function p:getRawMetadata(key)
		if key == 'virtualCopies' then
			local copy = {}
			for i, v in ipairs(self.virtualCopies) do copy[i] = v end
			return copy
		elseif key == 'isVirtualCopy' then
			return self.isVirtualCopy
		elseif key == 'path' then
			return self.path
		elseif key == 'fileFormat' then
			return self.fileFormat
		elseif key == 'masterPhoto' then
			return self.masterPhoto
		end
		error('mock: unknown raw metadata key ' .. tostring(key))
	end
	function p:getFormattedMetadata(key)
		if key == 'fileName' then return self.fileName end
		if key == 'copyName' then return self.copyName end
		error('mock: unknown formatted metadata key ' .. tostring(key))
	end
	function p:setRawMetadata(key, value)
		assert(state.inWrite, 'setRawMetadata called outside withWriteAccessDo')
		assert(key == 'copyName', 'mock: unsupported setRawMetadata key ' .. tostring(key))
		self.copyName = value
	end
	function p:getDevelopSettings()
		local copy = {}
		for k, v in pairs(self.developSettings) do copy[k] = v end
		return copy
	end
	function p:applyDevelopSettings(settings, historyName)
		assert(state.inWrite, 'applyDevelopSettings called outside withWriteAccessDo')
		local copy = {}
		for k, v in pairs(settings) do copy[k] = v end
		self.applied[#self.applied + 1] = { settings = copy, history = historyName }
		for k, v in pairs(settings) do self.developSettings[k] = v end
	end
	state.photos[#state.photos + 1] = p
	return p
end

function M.setup(opts)
	opts = opts or {}
	local state = {
		nextId = 0,
		photos = {},
		selection = {},
		inWrite = false,
		messages = {},
		collections = {},
		collectionSets = {},
		views = {},
		prefs = opts.prefs or {},
		dialogResult = opts.dialogResult or 'ok',
		vcMode = opts.vcMode or 'outside',
		ignoreCopyName = opts.ignoreCopyName or false,
		answers = opts.answers or {},
		tempDir = assert(opts.tempDir),
		executed = {},
		log = {},
	}

	local catalog = {}
	function catalog:getTargetPhotos()
		local copy = {}
		for i, p in ipairs(state.selection) do copy[i] = p end
		return copy
	end
	function catalog:setSelectedPhotos(active, others)
		local sel = {}
		if active and not active.hidden then sel[#sel + 1] = active end
		for _, p in ipairs(others or {}) do
			if not p.hidden then sel[#sel + 1] = p end
		end
		state.selection = sel
	end
	function catalog:createVirtualCopies(name)
		if state.vcMode == 'outside' and state.inWrite then
			error('mock: createVirtualCopies cannot be called inside withWriteAccessDo')
		elseif state.vcMode == 'inside' and not state.inWrite then
			error('LrCatalog:createVirtualCopies: must be called from within withWriteAccessDo')
		end
		local created = {}
		for _, master in ipairs(state.selection) do
			if master.isVirtualCopy then master = master.masterPhoto end
			if master.failSecondCopy and #master.virtualCopies >= 1 then
				error('mock: Lightroom refused to create another copy')
			end
			if state.ignoreCopyName then name = nil end
			local vc = newPhoto(state, {
				path = master.path, fileName = master.fileName, fileFormat = master.fileFormat,
				isVirtualCopy = true, masterPhoto = master, copyName = name or ('Copy ' .. (#master.virtualCopies + 1)),
				developSettings = master:getDevelopSettings(),
			})
			master.virtualCopies[#master.virtualCopies + 1] = vc
			created[#created + 1] = vc
		end
		state.selection = created
		return created
	end
	function catalog:withWriteAccessDo(name, fn, _)
		assert(not state.inWrite, 'nested withWriteAccessDo')
		state.inWrite = true
		local ok, err = pcall(fn, {})
		state.inWrite = false
		if not ok then error(err, 0) end
		return 'executed'
	end
	function catalog:createCollectionSet(name, parent, canReturnPrior)
		assert(state.inWrite, 'createCollectionSet outside write access')
		local key = name
		if not state.collectionSets[key] then
			state.collectionSets[key] = { name = name, parent = parent }
		elseif not canReturnPrior then
			return nil
		end
		return state.collectionSets[key]
	end
	function catalog:createCollection(name, parent, canReturnPrior)
		assert(state.inWrite, 'createCollection outside write access')
		local key = (parent and parent.name or '') .. '/' .. name
		if not state.collections[key] then
			local c = { name = name, parent = parent, photos = {} }
			function c:addPhotos(photos)
				assert(state.inWrite, 'addPhotos outside write access')
				for _, p in ipairs(photos) do self.photos[#self.photos + 1] = p end
			end
			state.collections[key] = c
		elseif not canReturnPrior then
			return nil
		end
		return state.collections[key]
	end

	local function callableObject(methods)
		return setmetatable({}, { __index = function(_, k)
			return methods[k] or function() end
		end })
	end

	local modules = {}
	modules.LrApplication = { activeCatalog = function() return catalog end }
	modules.LrApplicationView = {
		getCurrentModuleName = function() return state.module or 'develop' end,
		switchToModule = function(m) state.module = m; state.views[#state.views + 1] = 'module:' .. m end,
		showView = function(v) state.views[#state.views + 1] = 'view:' .. v end,
	}
	-- Property tables notify observers on change, like Lightroom's.
	modules.LrBinding = {
		makePropertyTable = function()
			local data, observers = {}, {}
			local t = {}
			function t:addObserver(key, fn)
				observers[key] = observers[key] or {}
				table.insert(observers[key], fn)
			end
			return setmetatable(t, {
				__index = data,
				__newindex = function(_, k, v)
					data[k] = v
					for _, fn in ipairs(observers[k] or {}) do fn(t, k, v) end
				end,
			})
		end,
	}
	modules.LrDialogs = {
		message = function(title, msg, style)
			state.messages[#state.messages + 1] = { title = title, message = msg, style = style }
		end,
		presentModalDialog = function(args)
			if args.title == 'Where should I cut?' then
				state.questions = (state.questions or 0) + 1
				local answer = table.remove(state.answers, 1)
				assert(answer, 'mock: unexpected question dialog')
				return answer(args.contents.args.bind_to_object, args, state)
			end
			state.dialog = args
			return state.dialogResult
		end,
		attachErrorDialogToFunctionContext = function() end,
	}
	modules.LrFileUtils = {
		exists = function(path)
			local f = io.open(path, 'rb')
			if f then f:close(); return 'file' end
			return false
		end,
		delete = function(path)
			state.deleted = state.deleted or {}
			state.deleted[#state.deleted + 1] = path
			return os.remove(path) ~= nil
		end,
	}
	modules.LrFunctionContext = {
		postAsyncTaskWithContext = function(_, fn) fn({}) end,
		callWithContext = function(_, fn, ...) return fn({}, ...) end,
	}
	modules.LrLogger = function()
		return callableObject({
			info = function(_, msg) state.log[#state.log + 1] = msg end,
		})
	end
	modules.LrPathUtils = {
		getStandardFilePath = function(which)
			assert(which == 'temp')
			return state.tempDir
		end,
		child = function(a, b) return a .. '/' .. b end,
		leafName = function(p) return p:match('[^/]+$') end,
	}
	modules.LrPrefs = { prefsForPlugin = function() return state.prefs end }
	modules.LrProgressScope = function(_)
		return callableObject({
			isCanceled = function() return state.cancelProgress == true end,
		})
	end
	modules.LrTasks = {
		execute = function(cmd)
			state.executed[#state.executed + 1] = cmd
			local r = os.execute(cmd)
			if type(r) == 'number' then return r end
			return r and 0 or 1
		end,
		pcall = pcall,
		startAsyncTask = function(fn) fn() end,
		sleep = function() end,
		yield = function() end,
	}
	local factory = setmetatable({}, { __index = function(_, k)
		return function(_, t) return { kind = k, args = t } end
	end })
	modules.LrView = {
		osFactory = function() return factory end,
		bind = function(k) return { bind = k } end,
	}

	_G.import = function(name)
		return assert(modules[name], 'mock: module not simulated: ' .. tostring(name))
	end
	_G.MAC_ENV = true
	_G.WIN_ENV = false

	state.catalog = catalog
	state.newPhoto = function(t) return newPhoto(state, t) end
	return state
end

return M
