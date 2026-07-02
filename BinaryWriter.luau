--!strict
--!optimize 2
-- BinaryWriter.luau
-- Core Engine untuk konversi Format Binary Roblox (.rbxl / .rbxm)

local BinaryWriter = {}

local MAGIC_HEADER = "<roblox!\x89\xff\x0d\x0a\x1a\x0a\x00\x00"

local function write_chunk(chunk_name: string, data: string): string
	local uncompressed_size = #data
	local compressed_size = 0 -- Bypass LZ4 sementara

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
	for i, z in numbers do
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
	local transformed = {}
	local last_val = 0
	for i, num in numbers do
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

local function build_PROP_String(class_index: number, prop_name: string, values: {string}): string
	local lengths, concat = {}, {}
	for i, str in values do
		lengths[i] = #str
		table.insert(concat, str)
	end
	return build_PROP_Header(class_index, prop_name, 1, interleave_zigzag(lengths) .. table.concat(concat))
end

local function build_PROP_Bool(class_index: number, prop_name: string, values: {boolean}): string
	local b = buffer.create(#values)
	for i, val in values do buffer.writeu8(b, i - 1, val and 1 or 0) end
	return build_PROP_Header(class_index, prop_name, 2, buffer.tostring(b))
end

local function build_PROP_Int(class_index: number, prop_name: string, values: {number}): string
	return build_PROP_Header(class_index, prop_name, 3, interleave_zigzag(values))
end

local function build_PROP_Float(class_index: number, prop_name: string, values: {number}): string
	local u32s = {}
	for i, v in values do u32s[i] = float_transform(v) end
	return build_PROP_Header(class_index, prop_name, 4, interleave_u32(u32s))
end

local function build_PROP_Vector3(class_index: number, prop_name: string, values: {Vector3}): string
	local x, y, z = {}, {}, {}
	for i, v in values do
		x[i] = float_transform(v.X)
		y[i] = float_transform(v.Y)
		z[i] = float_transform(v.Z)
	end
	return build_PROP_Header(class_index, prop_name, 8, interleave_u32(x) .. interleave_u32(y) .. interleave_u32(z))
end

local function build_PROP_Color3(class_index: number, prop_name: string, values: {Color3}): string
	local r, g, b = {}, {}, {}
	for i, v in values do
		r[i] = float_transform(v.R)
		g[i] = float_transform(v.G)
		b[i] = float_transform(v.B)
	end
	return build_PROP_Header(class_index, prop_name, 11, interleave_u32(r) .. interleave_u32(g) .. interleave_u32(b))
end

local function build_PROP_CFrame(class_index: number, prop_name: string, values: {CFrame}): string
	local ids = buffer.create(#values)
	local r00, r01, r02, r10, r11, r12, r20, r21, r22 = {}, {}, {}, {}, {}, {}, {}, {}, {}
	local px, py, pz = {}, {}, {}
	for i, cf in values do
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
	return build_PROP_Header(class_index, prop_name, 16, data)
end

local function build_PROP_Enum(class_index: number, prop_name: string, values: {any}): string
	local ints = {}
	for i, v in values do ints[i] = typeof(v) == "EnumItem" and v.Value or 0 end
	return build_PROP_Header(class_index, prop_name, 17, interleave_zigzag(ints))
end

-- ==========================================
-- KAMUS TIPE DATA DINAMIS
-- ==========================================
local TypeBuilders = {
	["string"] = build_PROP_String,
	["Content"] = build_PROP_String,
	["BinaryString"] = build_PROP_String,
	["bool"] = build_PROP_Bool,
	["int"] = build_PROP_Int,
	["int64"] = build_PROP_Int,
	["float"] = build_PROP_Float,
	["double"] = build_PROP_Float,
	["Vector3"] = build_PROP_Vector3,
	["Color3"] = build_PROP_Color3,
	["Color3uint8"] = build_PROP_Color3,
	["CFrame"] = build_PROP_CFrame,
	["Enum"] = build_PROP_Enum,
}

-- ==========================================
-- MAIN ENCODER (JEMBATAN PROPERTI)
-- ==========================================
local function extract_prop(instances, propName, valueType)
	local values = {}
	local has_data = false
	for i, inst in instances do
		local ok, val = pcall(function() return inst[propName] end)
		if ok and val ~= nil then
			values[i] = val
			has_data = true
		else
			if valueType == "string" or valueType == "Content" or valueType == "BinaryString" then values[i] = ""
			elseif valueType == "bool" then values[i] = false
			elseif valueType == "Vector3" then values[i] = Vector3.new()
			elseif valueType == "Color3" or valueType == "Color3uint8" then values[i] = Color3.new()
			elseif valueType == "CFrame" then values[i] = CFrame.new()
			elseif valueType == "int" or valueType == "float" or valueType == "double" or valueType == "int64" then values[i] = 0
			elseif valueType == "Enum" then values[i] = 0
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

	for i, inst in instances do instance_to_ref[inst] = i - 1 end

	for _, inst in instances do
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
	
	local f_header = buffer.create(16)
	buffer.writeu32(f_header, 0, #class_list)
	buffer.writeu32(f_header, 4, #instances)
	table.insert(chunks, buffer.tostring(f_header))

	local class_index_map = {}
	local class_index = 0
	for _, class_name in class_list do
		class_index_map[class_name] = class_index
		table.insert(chunks, build_INST(class_index, class_name, false, class_groups[class_name]))
		class_index += 1
	end

	-- EKSTRAKSI PROPERTI DINAMIS (NGAMBIL DARI API DUMP)
	for class_name, ids in class_groups do
		local class_instances = {}
		for _, id in ids do table.insert(class_instances, instances[id + 1]) end
		local c_idx = class_index_map[class_name]

		-- Kumpulkan semua jenis properti khusus untuk class ini (dan superclass-nya)
		local props_to_save = {}
		local layer = ClassList and ClassList[class_name]
		while layer do
			for _, prop in layer.Properties do
				table.insert(props_to_save, prop)
			end
			layer = ClassList[layer.Superclass]
		end

		-- Wajib nyatet "Nama" objek duluan
		local _, name_vals = extract_prop(class_instances, "Name", "string")
		table.insert(chunks, build_PROP_String(c_idx, "Name", name_vals))

		-- Tulis sisa propertinya berdasarkan kamus otomatis
		for _, prop in props_to_save do
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

	if #child_ids > 0 then
		table.insert(chunks, build_PRNT(child_ids, parent_ids))
	end

	table.insert(chunks, write_chunk("END\0", ""))
	return table.concat(chunks)
end

return BinaryWriter