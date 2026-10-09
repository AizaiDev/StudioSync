--!strict
--!native

const INITIAL_STATE = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 }
const ROUND_CONSTANTS = { 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xCA62C1D6 }
const BLOCK_BYTES = 64
const LENGTH_FIELD_BYTES = 8
const WORD_MODULUS = 2 ^ 32

const Sha1 = {}

function Sha1.Hex(message: string): string
	const length = #message
	const paddedLength = (length + 1 + LENGTH_FIELD_BYTES + BLOCK_BYTES - 1) // BLOCK_BYTES * BLOCK_BYTES
	const data = buffer.create(paddedLength)
	buffer.writestring(data, 0, message)
	buffer.writeu8(data, length, 0x80)
	const bitLength = length * 8
	buffer.writeu32(data, paddedLength - 8, bit32.byteswap(bitLength // WORD_MODULUS))
	buffer.writeu32(data, paddedLength - 4, bit32.byteswap(bitLength % WORD_MODULUS))

	local h0, h1, h2, h3, h4 = table.unpack(INITIAL_STATE)
	const words = table.create(80, 0)
	for blockStart = 0, paddedLength - 1, BLOCK_BYTES do
		for i = 1, 16 do
			words[i] = bit32.byteswap(buffer.readu32(data, blockStart + (i - 1) * 4))
		end
		for i = 17, 80 do
			words[i] = bit32.lrotate(bit32.bxor(words[i - 3], words[i - 8], words[i - 14], words[i - 16]), 1)
		end

		local a, b, c, d, e = h0, h1, h2, h3, h4
		for i = 1, 80 do
			local mixed, roundConstant
			if i <= 20 then
				mixed = bit32.bor(bit32.band(b, c), bit32.band(bit32.bnot(b), d))
				roundConstant = ROUND_CONSTANTS[1]
			elseif i <= 40 then
				mixed = bit32.bxor(b, c, d)
				roundConstant = ROUND_CONSTANTS[2]
			elseif i <= 60 then
				mixed = bit32.bor(bit32.band(b, c), bit32.band(b, d), bit32.band(c, d))
				roundConstant = ROUND_CONSTANTS[3]
			else
				mixed = bit32.bxor(b, c, d)
				roundConstant = ROUND_CONSTANTS[4]
			end
			const rotated = (bit32.lrotate(a, 5) + mixed + e + roundConstant + words[i]) % WORD_MODULUS
			e = d
			d = c
			c = bit32.lrotate(b, 30)
			b = a
			a = rotated
		end

		h0 = (h0 + a) % WORD_MODULUS
		h1 = (h1 + b) % WORD_MODULUS
		h2 = (h2 + c) % WORD_MODULUS
		h3 = (h3 + d) % WORD_MODULUS
		h4 = (h4 + e) % WORD_MODULUS
	end

	return string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
end

function Sha1.GitBlob(contents: string): string
	return Sha1.Hex(`blob {#contents}\0{contents}`)
end

return Sha1
