local M = {}

local MODULO = 4294967296
local floor = math.floor

local function normalize(value)
  return value % MODULO
end

local function fallback_band(left, right)
  local result = 0
  local bit_value = 1

  for _ = 1, 32 do
    local left_bit = left % 2
    local right_bit = right % 2
    if left_bit == 1 and right_bit == 1 then
      result = result + bit_value
    end
    left = floor(left / 2)
    right = floor(right / 2)
    bit_value = bit_value * 2
  end

  return result
end

local function fallback_bxor(left, right)
  local result = 0
  local bit_value = 1

  for _ = 1, 32 do
    local left_bit = left % 2
    local right_bit = right % 2
    if left_bit ~= right_bit then
      result = result + bit_value
    end
    left = floor(left / 2)
    right = floor(right / 2)
    bit_value = bit_value * 2
  end

  return result
end

local function fallback_rshift(value, amount)
  return floor(normalize(value) / (2 ^ amount))
end

local function fallback_ror(value, amount)
  local normalized = normalize(value)
  local right = fallback_rshift(normalized, amount)
  local left = (normalized * (2 ^ (32 - amount))) % MODULO
  return normalize(left + right)
end

local ok, bit = pcall(require, "bit")
local band
local bxor
local bnot
local rshift
local ror
local add

if ok then
  band = bit.band
  bxor = bit.bxor
  bnot = bit.bnot
  rshift = bit.rshift
  ror = bit.ror
  add = function(...)
    local result = 0
    for index = 1, select("#", ...) do
      result = result + select(index, ...)
    end
    return bit.tobit(result)
  end
else
  band = function(...)
    local values = { ... }
    local result = values[1]
    for index = 2, #values do
      result = fallback_band(result, values[index])
    end
    return result
  end
  bxor = function(...)
    local values = { ... }
    local result = values[1]
    for index = 2, #values do
      result = fallback_bxor(result, values[index])
    end
    return result
  end
  bnot = function(value)
    return 4294967295 - normalize(value)
  end
  rshift = fallback_rshift
  ror = fallback_ror
  add = function(...)
    local result = 0
    for index = 1, select("#", ...) do
      result = result + select(index, ...)
    end
    return normalize(result)
  end
end

local CONSTANTS = {
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
}

local INITIAL = {
  0x6a09e667,
  0xbb67ae85,
  0x3c6ef372,
  0xa54ff53a,
  0x510e527f,
  0x9b05688c,
  0x1f83d9ab,
  0x5be0cd19,
}

local function word_bytes(word)
  return string.char(
    floor(word / 16777216) % 256,
    floor(word / 65536) % 256,
    floor(word / 256) % 256,
    word % 256
  )
end

local function padded(message)
  local bit_length = #message * 8
  local padding_size = (56 - ((#message + 1) % 64)) % 64
  local high = floor(bit_length / MODULO)
  local low = bit_length % MODULO
  return message
    .. string.char(128)
    .. string.rep("\0", padding_size)
    .. word_bytes(high)
    .. word_bytes(low)
end

local function read_word(message, offset)
  local first, second, third, fourth = message:byte(offset, offset + 3)
  return first * 16777216 + second * 65536 + third * 256 + fourth
end

local function compress(state, message, offset, words)
  for index = 1, 16 do
    words[index] = read_word(message, offset + ((index - 1) * 4))
  end
  for index = 17, 64 do
    local earlier = words[index - 15]
    local later = words[index - 2]
    local sigma_zero = bxor(ror(earlier, 7), ror(earlier, 18), rshift(earlier, 3))
    local sigma_one = bxor(ror(later, 17), ror(later, 19), rshift(later, 10))
    words[index] = add(words[index - 16], sigma_zero, words[index - 7], sigma_one)
  end

  local a, b, c, d = state[1], state[2], state[3], state[4]
  local e, f, g, h = state[5], state[6], state[7], state[8]

  for index = 1, 64 do
    local sum_one = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
    local choice = bxor(band(e, f), band(bnot(e), g))
    local temporary_one = add(h, sum_one, choice, CONSTANTS[index], words[index])
    local sum_zero = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
    local majority = bxor(band(a, b), band(a, c), band(b, c))
    local temporary_two = add(sum_zero, majority)

    h = g
    g = f
    f = e
    e = add(d, temporary_one)
    d = c
    c = b
    b = a
    a = add(temporary_one, temporary_two)
  end

  state[1] = add(state[1], a)
  state[2] = add(state[2], b)
  state[3] = add(state[3], c)
  state[4] = add(state[4], d)
  state[5] = add(state[5], e)
  state[6] = add(state[6], f)
  state[7] = add(state[7], g)
  state[8] = add(state[8], h)
end

local function word_hex(word)
  return ("%02x%02x%02x%02x"):format(
    floor(word / 16777216) % 256,
    floor(word / 65536) % 256,
    floor(word / 256) % 256,
    word % 256
  )
end

function M.sha256(message)
  if type(message) ~= "string" then
    error("message must be a string", 2)
  end

  local state = {}
  for index = 1, #INITIAL do
    state[index] = INITIAL[index]
  end

  local input = padded(message)
  local words = {}
  for offset = 1, #input, 64 do
    compress(state, input, offset, words)
  end

  local result = {}
  for index = 1, #state do
    result[index] = word_hex(state[index])
  end
  return table.concat(result)
end

return M
