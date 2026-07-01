--!strict
--!optimize 2
-- BinaryWriter.luau
-- Core Engine untuk konversi Format Binary Roblox (.rbxl / .rbxm)

local BinaryWriter = {}

-- ==========================================
-- Konstanta Binary Roblox
-- ==========================================
-- Header wajib biar Roblox Studio tau ini file asli
local MAGIC_HEADER = "<roblox!\x89\xff\x0d\x0a\x1a\x0a\x00\x00"
-- Penanda akhir dari file binary
local END_CHUNK = "END\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"

-- ==========================================
-- 1. LZ4 COMPRESSION HANDLER (FULL ALGORITHM)
-- ==========================================
local function compress_data(data: string): (string, number)
	local uncompressed_size = #data
	if uncompressed_size == 0 then return "", 0 end

	-- Kamus Hash buat nyatet posisi byte yang pernah muncul
	local hash_table = table.create(65536, 0)
	local buffer_out = {}
	
	local i = 1
	local anchor = 1
	
	while i <= uncompressed_size do
		local match_len = 0
		local match_dist = 0
		
		-- Coba nyari kecocokan kalau masih ada minimal 4 byte sisa
		if i + 4 <= uncompressed_size then
			local b1, b2, b3, b4 = string.byte(data, i, i + 3)
			local seq = bit32.bor(bit32.lshift(b1, 24), bit32.lshift(b2, 16), bit32.lshift(b3, 8), b4)
			
			-- Hash sederhana anti-presisi jebol di Luau
			local hash = bit32.band(bit32.bxor(seq, bit32.rshift(seq, 16)), 0xFFFF) + 1 
			
			local ref = hash_table[hash]
			hash_table[hash] = i
			
			-- Kalau ketemu jejak di kamus dan jaraknya gak lebih dari batas LZ4
			if ref > 0 and (i - ref) <= 65535 then
				if string.byte(data, ref) == b1 and string.byte(data, ref+1) == b2 and string.byte(data, ref+2) == b3 and string.byte(data, ref+3) == b4 then
					match_dist = i - ref
					match_len = 4
					-- Lacak seberapa panjang rentetan kecocokannya
					while i + match_len <= uncompressed_size and string.byte(data, i + match_len) == string.byte(data, ref + match_len) do
						match_len += 1
					end
				end
			end
		end
		
		-- Kalau dapet kecocokan beruntun minimal 4 byte
		if match_len >= 4 then
			local lit_len = i - anchor
			local token_lit = lit_len >= 15 and 15 or lit_len
			local token_mat = (match_len - 4) >= 15 and 15 or (match_len - 4)
			local token = bit32.bor(bit32.lshift(token_lit, 4), token_mat)
			
			table.insert(buffer_out, string.char(token))
			
			if lit_len >= 15 then
				local l = lit_len - 15
				while l >= 255 do
					table.insert(buffer_out, string.char(255))
					l -= 255
				end
				table.insert(buffer_out, string.char(l))
			end
			
			if lit_len > 0 then
				table.insert(buffer_out, string.sub(data, anchor, i - 1))
			end
			
			-- Tulis Jarak (Little Endian)
			table.insert(buffer_out, string.char(bit32.band(match_dist, 0xFF), bit32.band(bit32.rshift(match_dist, 8), 0xFF)))
			
			if token_mat == 15 then
				local l = (match_len - 4) - 15
				while l >= 255 do
					table.insert(buffer_out, string.char(255))
					l -= 255
				end
				table.insert(buffer_out, string.char(l))
			end
			
			i += match_len
			anchor = i
		else
			i += 1
		end
	end
	
	-- Beresin sisa byte yang gak dapet pasangan (Literals)
	local lit_len = uncompressed_size - anchor + 1
	local token_lit = lit_len >= 15 and 15 or lit_len
	local token = bit32.lshift(token_lit, 4)
	
	table.insert(buffer_out, string.char(token))
	if lit_len >= 15 then
		local l = lit_len - 15
		while l >= 255 do
			table.insert(buffer_out, string.char(255))
			l -= 255
		end
		table.insert(buffer_out, string.char(l))
	end
	if lit_len > 0 then
		table.insert(buffer_out, string.sub(data, anchor, uncompressed_size))
	end
	
	return table.concat(buffer_out), uncompressed_size
end

-- ==========================================
-- 2. CHUNK WRITER (Pencetak Blok Data)
-- ==========================================
local function write_chunk(chunk_name: string, data: string): string
	local compressed_data, uncompressed_size = compress_data(data)
	local compressed_size = #compressed_data

	-- Total ukuran buffer: 16 byte header + ukuran data
	local b = buffer.create(16 + compressed_size)
	
	-- 4 Byte Pertama: Nama Chunk (INST, PROP, PRNT, dll)
	buffer.writestring(b, 0, string.sub(chunk_name, 1, 4))
	
	-- 4 Byte Kedua: Ukuran Data Terkompresi (Little Endian)
	buffer.writeu32(b, 4, compressed_size)
	
	-- 4 Byte Ketiga: Ukuran Data Asli (Little Endian)
	buffer.writeu32(b, 8, uncompressed_size)
	
	-- 4 Byte Keempat: Reserved (Selalu 0)
	buffer.writeu32(b, 12, 0)

	-- Tulis Datanya
	buffer.writestring(b, 16, compressed_data)

	return buffer.tostring(b)
end

-- ==========================================
-- 4. STRING TABLE (SSTR)
-- ==========================================
-- Ngumpulin semua teks unik biar irit memori
local function build_SSTR(strings: {string}): string
	local b_len = 8 
	for _, str in strings do
		b_len += 4 + #str
	end

	local b = buffer.create(b_len)
	buffer.writeu32(b, 0, 0) 
	buffer.writeu32(b, 4, #strings)

	local offset = 8
	for _, str in strings do
		buffer.writeu32(b, offset, #str)
		offset += 4
		buffer.writestring(b, offset, str)
		offset += #str
	end

	return write_chunk("SSTR", buffer.tostring(b))
end

-- ==========================================
-- 5. INTERLEAVE & ZIGZAG HELPERS (Otak Binary)
-- ==========================================
local function interleave_u32_array(numbers: {number}): string
	local count = #numbers
	if count == 0 then return "" end
	
	local b = buffer.create(count * 4)
	
	for i, num in numbers do
		local idx = i - 1
		
		-- ZigZag Transform (wajib dari Roblox biar angka minus jadi positif kecil)
		local x = num
		if x < 0 then x = x + 4294967296 end -- Ubah ke uint32
		local sign = bit32.arshift(x, 31)
		local z = bit32.bxor(bit32.lshift(x, 1), sign)
		
		-- Pecah jadi 4 byte (Big-Endian)
		local b1 = bit32.band(bit32.rshift(z, 24), 0xFF)
		local b2 = bit32.band(bit32.rshift(z, 16), 0xFF)
		local b3 = bit32.band(bit32.rshift(z, 8), 0xFF)
		local b4 = bit32.band(z, 0xFF)
		
		-- Tulis menyilang (Interleaving)
		buffer.writeu8(b, idx, b1)
		buffer.writeu8(b, count + idx, b2)
		buffer.writeu8(b, (count * 2) + idx, b3)
		buffer.writeu8(b, (count * 3) + idx, b4)
	end
	
	return buffer.tostring(b)
end

-- ==========================================
-- 6. INSTANCE CHUNK (INST)
-- ==========================================
local function build_INST(class_index: number, class_name_index: number, is_service: boolean, instance_ids: {number}): string
	local count = #instance_ids
	local b = buffer.create(13)
	
	buffer.writeu32(b, 0, class_index)
	buffer.writeu32(b, 4, class_name_index) -- ID teks dari SSTR
	buffer.writeu8(b, 8, is_service and 1 or 0)
	buffer.writeu32(b, 9, count)

	local interleaved_ids = interleave_u32_array(instance_ids)
	return write_chunk("INST", buffer.tostring(b) .. interleaved_ids)
end

-- ==========================================
-- 7. PARENT CHUNK (PRNT)
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
-- 8. PROPERTY CHUNK (PROP)
-- ==========================================
local function build_PROP(class_index: number, prop_name_index: number, prop_type: number, data_buffer: string): string
	local b = buffer.create(9)
	buffer.writeu32(b, 0, class_index)
	buffer.writeu32(b, 4, prop_name_index) 
	buffer.writeu8(b, 8, prop_type)
	
	return write_chunk("PROP", buffer.tostring(b) .. data_buffer)
end

-- ==========================================
-- 9. MAIN ENCODER (Pintu Masuk Utama)
-- ==========================================
function BinaryWriter.Serialize(instances: {Instance}, isModel: boolean): string
	local chunks = { MAGIC_HEADER }

	-- A. Kumpulin Teks (SSTR)
	local strings = {}
	local string_to_id = {}
	
	local function get_string_id(str: string): number
		if not string_to_id[str] then
			table.insert(strings, str)
			string_to_id[str] = #strings - 1 -- Roblox index mulai dari 0
		end
		return string_to_id[str]
	end

	-- B. Tracker Objek
	local class_groups = {} 
	local child_ids = {}
	local parent_ids = {}
	local instance_to_ref = {} 

	-- Kasih ID (Referent) ke semua objek, mulai dari 0
	for i, inst in instances do
		instance_to_ref[inst] = i - 1
	end

	-- Mapping data
	for _, inst in instances do
		local class_name = inst.ClassName
		local ref_id = instance_to_ref[inst]
		
		-- Daftarin Class
		if not class_groups[class_name] then
			class_groups[class_name] = {}
		end
		table.insert(class_groups[class_name], ref_id)
		
		-- Daftarin Hubungan (Parent-Child)
		if inst.Parent and instance_to_ref[inst.Parent] then
			table.insert(child_ids, ref_id)
			table.insert(parent_ids, instance_to_ref[inst.Parent])
		elseif isModel and inst.Parent == nil then
			table.insert(child_ids, ref_id)
			table.insert(parent_ids, -1) -- -1 berarti Root
		end
	end

	-- 1. Bikin SSTR Chunk
	local class_list = {}
	for class_name, _ in class_groups do
		table.insert(class_list, class_name)
		get_string_id(class_name)
	end
	table.insert(chunks, build_SSTR(strings))

	-- 2. Bikin INST Chunk
	local class_index = 0
	for _, class_name in class_list do
		local ids = class_groups[class_name]
		local name_idx = get_string_id(class_name)
		
		table.insert(chunks, build_INST(class_index, name_idx, false, ids))
		class_index += 1
	end

	-- 3. Bikin PROP Chunk
	-- (NANTI KITA ISI DI TAHAP SELANJUTNYA BUAT NULIS WARNA/POSISI)

	-- 4. Bikin PRNT Chunk
	if #child_ids > 0 then
		table.insert(chunks, build_PRNT(child_ids, parent_ids))
	end

	-- Chunk penutup wajib
	table.insert(chunks, write_chunk("END\0", ""))

	return table.concat(chunks)
end

return BinaryWriter