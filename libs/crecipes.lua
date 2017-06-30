local doc_addon = smart_inventory.doc_addon
local cache = smart_inventory.cache
local filter = smart_inventory.filter

local crecipes = {}
crecipes.crecipes = {} --list of all recipes

-----------------------------------------------------
-- crecipe: Class
-----------------------------------------------------
local crecipe_class = {}
crecipe_class.__index = crecipe_class
crecipes.crecipe_class = crecipe_class

-----------------------------------------------------
-- crecipes: analyze all data. Return false if invalid recipe. true on success
-----------------------------------------------------
function crecipe_class:analyze()
	-- check recipe output
	if self._recipe.output ~= "" then
		local out_itemname = self._recipe.output:gsub('"','')
		out_itemname = minetest.registered_aliases[out_itemname] or out_itemname
		self.out_item = minetest.registered_items[out_itemname]
		if not self.out_item then
			out_itemname:gsub("[^%s]+", function(z)
				local item = minetest.registered_aliases[z] or z
				if minetest.registered_items[item] then
					self.out_item = minetest.registered_items[item]
				end
			end)
		end
	else
		return false
	end
	if not self.out_item or not self.out_item.name then
		minetest.log("[smartfs_inventory] unknown recipe result "..self._recipe.output)
		return false
	end

	-- check recipe items/groups
	for _, recipe_item in pairs(self._recipe.items) do
		if recipe_item ~= "" then
			if self._items[recipe_item] then
				self._items[recipe_item].count = self._items[recipe_item].count + 1
			else
				self._items[recipe_item]  = {count = 1}
			end
		end
		for recipe_item, iteminfo in pairs(self._items) do
			if recipe_item:sub(1, 6) ~= "group:" then
				local itemname = minetest.registered_aliases[recipe_item] or recipe_item
				if minetest.registered_items[itemname] then
					iteminfo.items = {[itemname] = minetest.registered_items[itemname]}
				else
					minetest.log("[smartfs_inventory] unknown item in recipe: "..itemname.." for result "..self.out_item.name)
					return false
				end
			else
				if cache.cgroups[recipe_item] then
					iteminfo.items = cache.cgroups[recipe_item].items
				else
					local retitems
					for groupname in string.gmatch(recipe_item:sub(7), '([^,]+)') do
						if not retitems then --first entry
							if cache.cgroups[groupname] then
								retitems = table.copy(cache.cgroups[groupname].items)
							else
								groupname = groupname:gsub("_", ":")
								if cache.cgroups[groupname] then
									retitems = table.copy(cache.cgroups[groupname].items)
								else
									minetest.log("[smartfs_inventory] unknown group description in recipe: "..recipe_item.." / "..groupname.." for result "..self.out_item.name)
								end
							end
						else
							for itemname, itemdef in pairs(retitems) do
								local item_in_group = false
								for _, item_group in pairs(cache.citems[itemname].cgroups) do
									if item_group.name == groupname or
											item_group.name == groupname:gsub("_", ":")
									then
										item_in_group = true
										break
									end
								end
								if item_in_group == false then
									retitems[itemname] = nil
								end
							end
						end
					end
					if not retitems or not next(retitems) then
						minetest.log("[smartfs_inventory] no items matches group: "..recipe_item.." for result "..self.out_item.name)
						return false
					else
						iteminfo.items = retitems
					end
				end
			end
		end
	end
	-- invalid recipe
	if not self._items then
		minetest.log("[smartfs_inventory] skip recipe for: "..recipe_item)
		return false
	else
		return true
	end
end

-----------------------------------------------------
-- crecipes: Check if the recipe is revealed to the player
-----------------------------------------------------
function crecipe_class:is_revealed(playername)
	local recipe_valid = true
	for _, entry in pairs(self._items) do
		recipe_valid = false
		for _, itemdef in pairs(entry.items) do
			if doc_addon.is_revealed_item(itemdef.name, playername) then
				recipe_valid = true
				break
			end
		end
		if recipe_valid == false then
			return false
		end
	end
	return true
end

-----------------------------------------------------
-- crecipes: Returns recipe without groups, with replacements
-----------------------------------------------------
function crecipe_class:get_with_placeholder(player, inventory_tab)
	local recipe = table.copy(self._recipe)
	recipe.items = table.copy(recipe.items)
	for key, recipe_item in pairs(recipe.items) do
		local item

		-- Check for matching item in inventory
		if inventory_tab then
			local itemcount = 0
			for _, item_in_list in pairs(self._items[recipe_item].items) do
				local in_inventory = inventory_tab[item_in_list.name]
				if in_inventory == true then
					item = item_in_list.name
					break
				elseif in_inventory and in_inventory > itemcount then
					item = item_in_list.name
					itemcount = in_inventory
				end
			end
		end

		-- second try, get any revealed item
		if not item then
			for _, item_in_list in pairs(self._items[recipe_item].items) do
				if doc_addon.is_revealed_item(item_in_list.name, player) then
					item = item_in_list.name
					break
				end
			end
		end

		-- third try, just get one item
		if not item and self._items[recipe_item].items[1] then
			item = self._items[recipe_item].items[1].name
		end

		-- set recipe item
		if item then
			if recipe_item ~= item then
				recipe.items[key] = {
						item = item,
						tooltip = recipe_item,
						text = 'G',
					}
			end
		end
	end
	return recipe
end

-----------------------------------------------------
-- crecipes: Check if recipe contains only items provided in reference_items
-----------------------------------------------------
function crecipe_class:is_craftable_by_items(reference_items)
	local item_ok = false
	for _, entry in pairs(self._items) do
		item_ok = false
		for _, itemdef in pairs(entry.items) do
			if reference_items[itemdef.name] then
				item_ok = true
			end
		end
		if item_ok == false then
			break
		end
	end
	return item_ok
end

-----------------------------------------------------
-- crecipes: Check if the items placed in grid matches the recipe
-----------------------------------------------------
function crecipe_class:check_craftable_by_grid(grid)
	-- only "normal" recipes supported
	if self.recipe_type ~= "normal" then
		return false
	end

	for i = 1, 9 do
		local grid_item = grid[i]:get_name()
		-- check only fields filled in crafting grid
		if grid_item and grid_item ~= "" then
			-- check if item defined in recipe at this place
			local item_ok = false
			local recipe_item
			-- default case - 3x3 crafting grid
			local width = self._recipe.width
			if not width or width == 0 or width == 3 then
				recipe_item = self._recipe.items[i]
			else
				-- complex case - recalculate to the 3x3 crafting grid
				local x = math.fmod((i-1),3)+1
				if x <= width then
					local y = math.floor((i-1)/3+1)
					local coord = (y-1)*width+x
					recipe_item = self._recipe.items[coord]
				else
					recipe_item = ""
				end
			end

			if not recipe_item or recipe_item == "" then
				return false
			end

			-- check if it is a compatible item
			for _, itemdef in pairs(self._items[recipe_item].items) do
				if itemdef.name == grid_item then
					item_ok = true
					break
				end
			end
			if not item_ok then
				return false
			end
		end
	end
	return true
end

-----------------------------------------------------
-- Recipe object Constructor
-----------------------------------------------------
function crecipes.new(recipe)
	local def = {}
	def.out_item = nil
	def._recipe = recipe
	def.recipe_type = recipe.type
	def._items = {}
	setmetatable(def, crecipe_class)
	def.__index = crecipe_class
	return def
end

-----------------------------------------------------
-- Get all revealed recipes with at least one item in reference_items table
-----------------------------------------------------
function crecipes.get_revealed_recipes_with_items(playername, reference_items)
	local recipelist = {}
	for itemname, _ in pairs(reference_items) do
		if cache.citems[itemname] and cache.citems[itemname].in_craft_recipe then
			for _, recipe in ipairs(cache.citems[itemname].in_craft_recipe) do
				local crecipe = crecipes.crecipes[recipe]
				if crecipe and crecipe:is_revealed(playername) then
					recipelist[recipe] = crecipe
				end
			end
		end
	end
	return recipelist
end

-----------------------------------------------------
-- Get all recipes with all required items in reference items
-----------------------------------------------------
function crecipes.get_recipes_craftable(playername, reference_items)
	local all = crecipes.get_revealed_recipes_with_items(playername, reference_items)
	local craftable = {}
	for recipe, crecipe in pairs(all) do
		if crecipe:is_craftable_by_items(reference_items) then
			craftable[recipe] = crecipe
		end
	end
	return craftable
end

-----------------------------------------------------
-- Get all recipes that match to already placed items on crafting grid
-----------------------------------------------------
function crecipes.get_recipes_started_craft(playername, grid, reference_items)
	local all = crecipes.get_revealed_recipes_with_items(playername, reference_items)
	local craftable = {}
	for recipe, crecipe in pairs(all) do
		if crecipe:check_craftable_by_grid(grid) then
			craftable[recipe] = crecipe
		end
	end
	return craftable
end

function crecipes.add_recipes_from_list(recipelist)
	if recipelist then
		for _, recipe in ipairs(recipelist) do
			local recipe_obj = crecipes.new(recipe)
			if recipe_obj:analyze() then
				-- probably hidden therefore not indexed previous. But Items with recipe should be allways visible
				cache.add_item(minetest.registered_items[recipe_obj.out_item.name])
				table.insert(cache.citems[recipe_obj.out_item.name].in_output_recipe, recipe)
				crecipes.crecipes[recipe] = recipe_obj
				if recipe_obj.recipe_type ~= "normal" then
					cache.assign_to_group("recipetype:"..recipe_obj.recipe_type, recipe_obj.out_item, filter.get("recipetype"))
				end
				for _, entry in pairs(recipe_obj._items) do
					for itemname, itemdef in pairs(entry.items) do
						cache.add_item(itemdef) -- probably hidden therefore not indexed previous. But Items with recipe should be allways visible
						table.insert(cache.citems[itemdef.name].in_craft_recipe, recipe)
						cache.assign_to_group("ingredient:"..itemdef.name, recipe_obj.out_item, filter.get("ingredient"))
					end
				end
			end
		end
	end
end

-----------------------------------------------------
-- Fill the recipes cache at init
-----------------------------------------------------
local function fill_recipe_cache()
	for itemname, _ in pairs(minetest.registered_items) do
		crecipes.add_recipes_from_list(minetest.get_all_craft_recipes(itemname))
	end
	for itemname, _ in pairs(minetest.registered_aliases) do
		crecipes.add_recipes_from_list(minetest.get_all_craft_recipes(itemname))
	end
end
-- register to process after cache is filled
cache.register_on_cache_filled(fill_recipe_cache)

return crecipes
