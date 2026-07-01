--!strict
--!optimize 2
-- BinaryWriter.luau
-- Core Engine untuk konversi Format Binary Roblox (.rbxl / .rbxm)

local BinaryWriter = {}

local MAGIC_HEADER = "<roblox!\x89\xff\x0d\x0a\x1a\x0a\x00\x00"

-- ==========================================
-- 1. CHUNK WRITER (Pencetak Blok Data)
-- ==========================================
local function write_chunk(chunk_name: string, data: string): string
	local uncompressed_size = #data
	local compressed_size = 0 -- Bypass LZ4 sementara buat ngetes struktur

	local b = buffer.create(16 + uncompressed_size)
	buffer.writestring(b, 0, string.sub(chunk_name, 1, 4))
	buffer.writeu32(b, 4, compressed_size)
	buffer.writeu32(b, 8, uncompressed_size)
	buffer.writeu32(b, 12, 0)
	buffer.writestring(b, 16, data)

	return buffer.tostring(b)
end

-- ==========================================
-- 2. INTERLEAVE & ZIGZAG HELPERS
-- ==========================================
local function interleave_u32_array(numbers: {number}): string
	local count = #numbers
	if count == 0 then return "" end
	
	local b = buffer.create(count * 4)
	for i, num in numbers do
		local idx = i - 1
		local x = num
		if x < 0 then x = x + 4294967296 end
		local sign = bit32.arshift(x, 31)
		local z = bit32.bxor(bit32.lshift(x, 1), sign)
		
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

-- ==========================================
-- 3. INSTANCE CHUNK (INST)
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

	local interleaved_ids = interleave_u32_array(instance_ids)
	return write_chunk("INST", buffer.tostring(b) .. interleaved_ids)
end

-- ==========================================
-- 4. PARENT CHUNK (PRNT)
-- ==========================================
local function build_PRNT(child_ids: {number}, parent_ids: {number}): string
	local count = #child_ids
	local b = buffer.create(5)
	buffer.writeu8(b, 0, 0) 
	buffer.writeu32(b, 1, count)
	
	local child_interleaved = interleave_u32_array(child_ids)
	local parent_interleaved = interleave_u32_array(parent_ids)
	
	return write_chunk("PRNT", buffer.tostring(b) .. child_interleaved .. parent_interleaved)
end

-- ==========================================
-- 5. PROPERTY CHUNK (PROP)
-- ==========================================
local function build_PROP(class_index: number, prop_name: string, prop_type: number, data_buffer: string): string
	local name_len = #prop_name
	local b = buffer.create(9 + name_len)
	buffer.writeu32(b, 0, class_index)
	buffer.writeu32(b, 4, name_len)
	buffer.writestring(b, 8, prop_name)
	buffer.writeu8(b, 8 + name_len, prop_type)
	
	return write_chunk("PROP", buffer.tostring(b) .. data_buffer)
end

-- ==========================================
-- 6. MAIN ENCODER (Pintu Masuk Utama)
-- ==========================================
function BinaryWriter.Serialize(instances: {Instance}, isModel: boolean): string
	local chunks = { MAGIC_HEADER }

	local class_groups = {} 
	local child_ids = {}
	local parent_ids = {}
	local instance_to_ref = {} 

	for i, inst in instances do
		instance_to_ref[inst] = i - 1
	end

	for _, inst in instances do
		local class_name = inst.ClassName
		local ref_id = instance_to_ref[inst]
		
		if not class_groups[class_name] then
			class_groups[class_name] = {}
		end
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
	for class_name, _ in class_groups do
		table.insert(class_list, class_name)
	end
	
	local f_header = buffer.create(16)
	buffer.writeu32(f_header, 0, #class_list)
	buffer.writeu32(f_header, 4, #instances)
	table.insert(chunks, buffer.tostring(f_header))

	local class_index = 0
	for _, class_name in class_list do
		local ids = class_groups[class_name]
		table.insert(chunks, build_INST(class_index, class_name, false, ids))
		class_index += 1
	end

	if #child_ids > 0 then
		table.insert(chunks, build_PRNT(child_ids, parent_ids))
	end

	table.insert(chunks, write_chunk("END\0", ""))

	return table.concat(chunks)
end

return BinaryWriter