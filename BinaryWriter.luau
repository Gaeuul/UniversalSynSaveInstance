--!strict
--!optimize 2
-- BinaryWriter.luau
-- Core Engine untuk konversi Format Binary Roblox (.rbxl / .rbxm)

local BinaryWriter = {}

local MAGIC_HEADER = "<roblox!\x89\xff\x0d\x0a\x1a\x0a\x00\x00"

local function write_chunk(chunk_name: string, data: string): string
	local uncompressed_size = #data
	local compressed_size = 0 -- Bypass LZ4 sementara buat kestabilan

	local b = buffer.create(16 + uncompressed_size)
	buffer.writestring(b, 0, string.sub(chunk_name, 1, 4))
	buffer.writeu32(b, 4, compressed_size)
	buffer.writeu32(b, 8, uncompressed_size)
	buffer.writeu32(b, 12, 0)
	buffer.writestring(b, 16, data)

	return buffer.tostring(b)
end

-- ==========================================
-- HELPER MATEMATIKA
-- ==========================================
local function interleave_u32(numbers: {number}): string
	local count = #numbers
	if count == 0 then return "" end
	local b = buffer.create(count * 4)
	for i = 1, count do 
		local z = numbers[i]
		local idx = i - 1
		local b1 = bit32.band(bit32.rshift(z, 24), 0xFF)
		local b2 = bit32.band(bit32.rshift(z, 16), 0xFF)
		local b3 = bit32.band(bit32.rshift(z, 8), 0xFF)
		local b4 = bit32.band(z, 0xFF)
		buffer.writeu8(b, idx, b1)
		buffer.writeu8(b, count + idx, b2)
		buffer.writeu8(b, (count * 2) + idx, b3)
		buffer.writeu8(b, (count * 3) + idx, b4)
	end
	return buffer.tostring(b)
end

local function interleave_zigzag(numbers: {number}): string
	local count = #numbers
	local transformed = table.create(count)
	local last_val = 0
	for i = 1, count do
		local num = numbers[i]
		local delta = num - last_val
		last_val = num
		local x = delta
		if x < 0 then x = x + 4294967296 end
		local sign = bit32.arshift(x, 31)
		transformed[i] = bit32.bxor(bit32.lshift(x, 1), sign)
	end
	return interleave_u32(transformed)
end

local function float_transform(f: number): number
	local b = buffer.create(4)
	buffer.writef32(b, 0, f)
	local i = buffer.readu32(b, 0)
	local sign = bit32.rshift(i, 31)
	local shl = bit32.lshift(i, 1)
	if sign == 1 then return bit32.bnot(shl) else return shl end
end

-- ==========================================
-- CHUNK BUILDERS
-- ==========================================
local function build_INST(class_index: number, class_name: string, is_service: boolean, instance_ids: {number}): string
	local count = #instance_ids
	local name_len = #class_name
	
	local b = buffer.create(13 + name_len)
	buffer.writeu32(b, 0, class_index)
	buffer.writeu32(b, 4, name_len)
	buffer.writestring(b, 8, class_name)
	buffer.writeu8(b, 8 + name_len, is_service and 1 or 0)
	buffer.writeu32(b, 9 + name_len, count)
	
	return write_chunk("INST", buffer.tostring(b) .. interleave_zigzag(instance_ids))
end

local function build_PRNT(child_ids: {number}, parent_ids: {number}): string
	local b = buffer.create(5)
	buffer.writeu8(b, 0, 0) 
	buffer.writeu32(b, 1, #child_ids)
	return write_chunk("PRNT", buffer.tostring(b) .. interleave_zigzag(child_ids) .. interleave_zigzag(parent_ids))
end

local function build_PROP_Header(class_index: number, prop_name: string, prop_type: number, data: string): string
	local name_len = #prop_name
	
	local b = buffer.create(9 + name_len)
	buffer.writeu32(b, 0, class_index)
	buffer.writeu32(b, 4, name_len)
	buffer.writestring(b, 8, prop_name)
	buffer.writeu8(b, 8 + name_len, prop_type)
	
	return write_chunk("PROP", buffer.tostring(b) .. data)
end

-- ==========================================
-- PROPERTY VALUE BUILDERS (100% FIXED IDs!)
-- ==========================================
local function build_PROP_String(class_index: number, prop_name: string, values: {string}): string
	local count = #values
	local b_len = 0
	for i = 1, count do b_len += 4 + #values[i] end

	local b = buffer.create(b_len)
	local offset = 0
	for i = 1, count do
		local str = values[i]
		local slen = #str
		buffer.writeu32(b, offset, slen)
		offset += 4
		buffer.writestring(b, offset, str)
		offset += slen
	end
	return build_PROP_Header(class_index, prop_name, 1, buffer.tostring(b)) -- Tipe 1: String
end

local function build_PROP_Bool(class_index: number, prop_name: string, values: {boolean}): string
	local count = #values
	local b = buffer.create(count)
	for i = 1, count do buffer.writeu8(b, i - 1, values[i] and 1 or 0) end
	return build_PROP_Header(class_index, prop_name, 2, buffer.tostring(b)) -- Tipe 2: Bool
end

local function build_PROP_Int(class_index: number, prop_name: string, values: {number}): string
	return build_PROP_Header(class_index, prop_name, 3, interleave_zigzag(values)) -- Tipe 3: Int32
end

local function build_PROP_Float(class_index: number, prop_name: string, values: {number}): string
	local count = #values
	local u32s = table.create(count)
	for i = 1, count do u32s[i] = float_transform(values[i]) end
	return build_PROP_Header(class_index, prop_name, 4, interleave_u32(u32s)) -- Tipe 4: Float
end

local function build_PROP_UDim2(class_index: number, prop_name: string, values: {UDim2}): string
	local count = #values
	local sX, sY, oX, oY = table.create(count), table.create(count), table.create(count), table.create(count)
	for i = 1, count do
		local v = values[i]
		sX[i] = float_transform(v.X.Scale)
		sY[i] = float_transform(v.Y.Scale)
		oX[i] = v.X.Offset
		oY[i] = v.Y.Offset
	end
	return build_PROP_Header(class_index, prop_name, 7, interleave_u32(sX) .. interleave_u32(sY) .. interleave_zigzag(oX) .. interleave_zigzag(oY)) -- Tipe 7: UDim2
end

local function build_PROP_BrickColor(class_index: number, prop_name: string, values: {BrickColor}): string
	local count = #values
	local ints = table.create(count)
	for i = 1, count do ints[i] = values[i].Number end
	return build_PROP_Header(class_index, prop_name, 11, interleave_u32(ints)) -- Tipe 11: BrickColor
end

local function build_PROP_Color3(class_index: number, prop_name: string, values: {Color3}): string
	local count = #values
	local r, g, b = table.create(count), table.create(count), table.create(count)
	for i = 1, count do
		local v = values[i]
		r[i] = float_transform(v.R)
		g[i] = float_transform(v.G)
		b[i] = float_transform(v.B)
	end
	return build_PROP_Header(class_index, prop_name, 12, interleave_u32(r) .. interleave_u32(g) .. interleave_u32(b)) -- Tipe 12: Color3
end

local function build_PROP_Vector2(class_index: number, prop_name: string, values: {Vector2}): string
	local count = #values
	local x, y = table.create(count), table.create(count)
	for i = 1, count do
		local v = values[i]
		x[i] = float_transform(v.X)
		y[i] = float_transform(v.Y)
	end
	return build_PROP_Header(class_index, prop_name, 13, interleave_u32(x) .. interleave_u32(y)) -- Tipe 13: Vector2
end

local function build_PROP_Vector3(class_index: number, prop_name: string, values: {Vector3}): string
	local count = #values
	local x, y, z = table.create(count), table.create(count), table.create(count)
	for i = 1, count do
		local v = values[i]
		x[i] = float_transform(v.X)
		y[i] = float_transform(v.Y)
		z[i] = float_transform(v.Z)
	end
	return build_PROP_Header(class_index, prop_name, 14, interleave_u32(x) .. interleave_u32(y) .. interleave_u32(z)) -- Tipe 14: Vector3
end

local function build_PROP_CFrame(class_index: number, prop_name: string, values: {CFrame}): string
	local count = #values
	local ids = buffer.create(count)
	local r00, r01, r02 = table.create(count), table.create(count), table.create(count)
	local r10, r11, r12 = table.create(count), table.create(count), table.create(count)
	local r20, r21, r22 = table.create(count), table.create(count), table.create(count)
	local px, py, pz = table.create(count), table.create(count), table.create(count)
	for i = 1, count do
		local cf = values[i]
		buffer.writeu8(ids, i - 1, 0)
		local x, y, z, r1, r2, r3, r4, r5, r6, r7, r8, r9 = cf:GetComponents()
		px[i] = float_transform(x) py[i] = float_transform(y) pz[i] = float_transform(z)
		r00[i] = float_transform(r1) r01[i] = float_transform(r2) r02[i] = float_transform(r3)
		r10[i] = float_transform(r4) r11[i] = float_transform(r5) r12[i] = float_transform(r6)
		r20[i] = float_transform(r7) r21[i] = float_transform(r8) r22[i] = float_transform(r9)
	end
	local data = buffer.tostring(ids) 
		.. interleave_u32(r00) .. interleave_u32(r01) .. interleave_u32(r02)
		.. interleave_u32(r10) .. interleave_u32(r11) .. interleave_u32(r12)
		.. interleave_u32(r20) .. interleave_u32(r21) .. interleave_u32(r22)
		.. interleave_u32(px) .. interleave_u32(py) .. interleave_u32(pz)
	return build_PROP_Header(class_index, prop_name, 16, data) -- Tipe 16: CFrame
end

local function build_PROP_Enum(class_index: number, prop_name: string, values: {any}): string
	local count = #values
	local ints = table.create(count)
	for i = 1, count do
		local v = values[i]
		ints[i] = typeof(v) == "EnumItem" and v.Value or 0
	end
	return build_PROP_Header(class_index, prop_name, 18, interleave_u32(ints)) -- Tipe 18: Enum
end

local function build_PROP_Color3uint8(class_index: number, prop_name: string, values: {Color3}): string
	local count = #values
	local b = buffer.create(count * 3)
	for i = 1, count do
		local v = values[i]
		buffer.writeu8(b, (i - 1), math.round(v.R * 255))
		buffer.writeu8(b, count + (i - 1), math.round(v.G * 255))
		buffer.writeu8(b, (count * 2) + (i - 1), math.round(v.B * 255))
	end
	return build_PROP_Header(class_index, prop_name, 26, buffer.tostring(b)) -- Tipe 26: Color3uint8
end

-- ==========================================
-- KAMUS TIPE DATA DINAMIS
-- ==========================================
local TypeBuilders = {
	["string"] = build_PROP_String,
	["Content"] = build_PROP_String,
	["BinaryString"] = build_PROP_String,
	["ProtectedString"] = build_PROP_String, 
	["bool"] = build_PROP_Bool,
	["int"] = build_PROP_Int,
	["float"] = build_PROP_Float,
	["UDim2"] = build_PROP_UDim2,
	["BrickColor"] = build_PROP_BrickColor,
	["Color3"] = build_PROP_Color3,
	["Vector2"] = build_PROP_Vector2,
	["Vector3"] = build_PROP_Vector3,
	["CFrame"] = build_PROP_CFrame,
	["Enum"] = build_PROP_Enum,
	["Color3uint8"] = build_PROP_Color3uint8,
}

-- ==========================================
-- MAIN ENCODER (JEMBATAN PROPERTI)
-- ==========================================
local function extract_prop(instances, propName, valueType)
	local count = #instances
	local values = table.create(count)
	local has_data = false
	for i = 1, count do
		local inst = instances[i]
		local ok, val = pcall(function() return inst[propName] end)
		
		if ok and val ~= nil then
			if valueType == "string" or valueType == "Content" or valueType == "BinaryString" or valueType == "ProtectedString" then
				values[i] = type(val) == "string" and val or tostring(val)
			else
				values[i] = val
			end
			has_data = true
		else
			if valueType == "string" or valueType == "Content" or valueType == "BinaryString" or valueType == "ProtectedString" then values[i] = ""
			elseif valueType == "bool" then values[i] = false
			elseif valueType == "Vector2" then values[i] = Vector2.new()
			elseif valueType == "Vector3" then values[i] = Vector3.new()
			elseif valueType == "Color3" or valueType == "Color3uint8" then values[i] = Color3.new()
			elseif valueType == "BrickColor" then values[i] = BrickColor.new("Medium stone grey")
			elseif valueType == "CFrame" then values[i] = CFrame.new()
			elseif valueType == "int" or valueType == "float" then values[i] = 0
			elseif valueType == "Enum" then values[i] = 0
			elseif valueType == "UDim2" then values[i] = UDim2.new()
			else values[i] = nil end
		end
	end
	return has_data, values
end

function BinaryWriter.Serialize(instances: {Instance}, isModel: boolean, ClassList: any): string
	local chunks = { MAGIC_HEADER }

	local class_groups = {} 
	local child_ids, parent_ids = {}, {}
	local instance_to_ref = {} 

	for i = 1, #instances do instance_to_ref[instances[i]] = i - 1 end

	for i = 1, #instances do
		local inst = instances[i]
		local class_name = inst.ClassName
		local ref_id = instance_to_ref[inst]
		
		if not class_groups[class_name] then class_groups[class_name] = {} end
		table.insert(class_groups[class_name], ref_id)
		
		if inst.Parent and instance_to_ref[inst.Parent] then
			table.insert(child_ids, ref_id)
			table.insert(parent_ids, instance_to_ref[inst.Parent])
		elseif isModel and inst.Parent == nil then
			table.insert(child_ids, ref_id)
			table.insert(parent_ids, -1)
		end
	end

	local class_list = {}
	for class_name, _ in class_groups do table.insert(class_list, class_name) end
	
	local class_props_map = {}
	
	for i = 1, #class_list do
		local class_name = class_list[i]
		local props_to_save = {}
		local seen_props = {}
		local layer = ClassList and ClassList[class_name]
		while layer do
			if layer.Properties then
				for j = 1, #(layer.Properties) do
					local prop = layer.Properties[j]
					if not seen_props[prop.Name] then
						seen_props[prop.Name] = true
						table.insert(props_to_save, prop)
					end
				end
			end
			layer = ClassList[layer.Superclass]
		end
		class_props_map[class_name] = props_to_save
	end

	-- GLOBAL HEADER
	local f_header = buffer.create(16)
	buffer.writeu32(f_header, 0, #class_list)
	buffer.writeu32(f_header, 4, #instances)
	table.insert(chunks, buffer.tostring(f_header))

	-- INST CHUNK
	local class_index_map = {}
	local class_index = 0
	for i = 1, #class_list do
		local class_name = class_list[i]
		class_index_map[class_name] = class_index
		
		table.insert(chunks, build_INST(class_index, class_name, false, class_groups[class_name]))
		class_index += 1
	end

	-- PROP CHUNK
	for i = 1, #class_list do
		local class_name = class_list[i]
		local ids = class_groups[class_name]
		
		local class_instances = table.create(#ids)
		for j = 1, #ids do
			class_instances[j] = instances[ids[j] + 1]
		end
		
		local c_idx = class_index_map[class_name]
		local props_to_save = class_props_map[class_name]

		local _, name_vals = extract_prop(class_instances, "Name", "string")
		table.insert(chunks, build_PROP_String(c_idx, "Name", name_vals))

		for j = 1, #props_to_save do
			local prop = props_to_save[j]
			local pName = prop.Name
			local pType = prop.ValueType
			
			if pName == "Name" then continue end

			local builder = TypeBuilders[pType]
			if builder then
				local has_data, values = extract_prop(class_instances, pName, pType)
				if has_data then
					table.insert(chunks, builder(c_idx, pName, values))
				end
			end
		end
	end

	-- PRNT CHUNK
	if #child_ids > 0 then
		table.insert(chunks, build_PRNT(child_ids, parent_ids))
	end

	-- END CHUNK
	table.insert(chunks, write_chunk("END\0", ""))
	return table.concat(chunks)
end

return BinaryWriter