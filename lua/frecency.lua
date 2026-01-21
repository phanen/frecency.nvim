---START INJECT frecency.lua

local api, fn = vim.api, vim.fn
local M = {}

local ffi = require('ffi')

ffi.cdef [[
typedef long off_t;

int open(const char *pathname, int flags, int mode);
void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
int munmap(void *addr, size_t length);
int msync(void *addr, size_t length, int flags);
int close(int fd);
int ftruncate(int fd, off_t length);

enum {
  O_RDWR = 2,
  O_CREAT = 64,
  PROT_READ = 1,
  PROT_WRITE = 2,
  MAP_SHARED = 1,
  MAP_FAILED = -1,
  MS_SYNC = 4,
};
]]

local MAX_ENTRIES = 10000
local MAX_PATH_LEN = 255
local HALF_LIFE = 30 * 24 * 3600
local LAMBDA = math.log(2) / HALF_LIFE
local MMAP_FILE = '/tmp/nvim_frecency'
local PERSIST_FILE = fn.stdpath('data') .. '/frecency.dat'

ffi.cdef([[
typedef struct {
    char path[256];
    double deadline;
} frecency_entry_t;

typedef struct {
    uint32_t magic;
    uint32_t count;
    frecency_entry_t entries[]] .. MAX_ENTRIES .. [[];
} frecency_mmap_t;
]])

---@class frecency_entry_t
---@field path integer[]
---@field deadline number

---@class frecency_mmap_t
---@field magic number
---@field count number
---@field entries frecency_entry_t[]

local MMAP_SIZE = ffi.sizeof('frecency_mmap_t')

---@type frecency_mmap_t?
local data
---@type boolean
local initialized = false

---@param deadline number
---@return number
local to_score = function(deadline) return math.exp(LAMBDA * (deadline - os.time())) end

---@param score number
---@return number
local to_deadline = function(score) return os.time() + math.log(score) / LAMBDA end

---@param path string
---@return integer? index (0-based)
local find_entry = function(path)
  if not data then return end
  for i = 0, data.count - 1 do
    if ffi.string(data.entries[i].path) == path then return i end
  end
end

local load_from_file = function()
  if not data then return end
  local f = io.open(PERSIST_FILE, 'r')
  if not f then return end
  for line in f:lines() do ---@cast line string
    local len_str, rest = line:match('^(%d+) (.*)$')
    if len_str and rest then
      local len = tonumber(len_str) ---@as integer
      local path = rest:sub(1, len)
      local deadline = tonumber(rest:sub(len + 2))
      if path and deadline and data.count < MAX_ENTRIES then
        local i = data.count
        local path_len = math.min(#path, MAX_PATH_LEN)
        ffi.copy(data.entries[i].path, path, path_len)
        data.entries[i].path[path_len] = 0
        data.entries[i].deadline = deadline
        data.count = data.count + 1
      end
    end
  end
  f:close()
end

local save_to_file = function()
  if not data then return end
  local lines = {}
  for i = 0, data.count - 1 do
    local path = ffi.string(data.entries[i].path)
    lines[#lines + 1] = string.format('%d %s %.6f', #path, path, data.entries[i].deadline)
  end
  local dir = fn.fnamemodify(PERSIST_FILE, ':h')
  fn.mkdir(dir, 'p')
  local f = io.open(PERSIST_FILE, 'w')
  if f then
    f:write(table.concat(lines, '\n'))
    f:close()
  end
end

local lowest = function()
  if not data or data.count == 0 then return end
  local min_idx = 0
  local min_score = to_score(data.entries[0].deadline)
  for i = 1, data.count - 1 do
    local score = to_score(data.entries[i].deadline)
    if score < min_score then
      min_idx = i
      min_score = score
    end
  end
  return min_idx
end

---@param idx integer
---@return boolean? success
local evict = function(idx)
  if not data or data.count == 0 then return end
  data.entries[idx] = data.entries[data.count - 1]
  data.count = data.count - 1
  return true
end

---@return boolean? success
local evict_lowest = function()
  local idx = lowest()
  if idx then return evict(idx) end
end

---@return boolean success
M.init = function()
  if initialized then return true end

  local fd = ffi.C.open(MMAP_FILE, bit.bor(ffi.C.O_RDWR, ffi.C.O_CREAT), tonumber('0666', 8))
  if fd < 0 then
    vim.notify('frecency: Failed to open mmap file', vim.log.levels.ERROR)
    return false
  end

  ffi.C.ftruncate(fd, MMAP_SIZE)

  local ptr =
    ffi.C.mmap(nil, MMAP_SIZE, bit.bor(ffi.C.PROT_READ, ffi.C.PROT_WRITE), ffi.C.MAP_SHARED, fd, 0)

  ffi.C.close(fd)

  if tonumber(ffi.cast('intptr_t', ptr)) == ffi.C.MAP_FAILED then
    vim.notify('frecency: Failed to mmap', vim.log.levels.ERROR)
    return false
  end

  data = ffi.cast('frecency_mmap_t*', ptr) ---@as frecency_mmap_t

  if data.magic ~= 0x46524543 then
    data.magic = 0x46524543
    data.count = 0
    load_from_file()
  end

  initialized = true
  return true
end

---@param buf integer
---@param value? number
M.visit_buf = function(buf, value)
  if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' or not vim.bo[buf].buflisted then
    return
  end
  local file = api.nvim_buf_get_name(buf)
  if file == '' or not vim.uv.fs_stat(file) then return end
  M.visit(file, value)
end

M.find_entry = find_entry

---@param path string
---@param value? number
M.visit = function(path, value)
  if not initialized or not data then return end

  value = value or 1
  local idx = find_entry(path)

  if idx then
    local score = to_score(data.entries[idx].deadline) + value
    data.entries[idx].deadline = to_deadline(score)
  else
    if data.count >= MAX_ENTRIES then evict_lowest() end
    local i = data.count
    local len = math.min(#path, MAX_PATH_LEN)
    ffi.copy(data.entries[i].path, path, len)
    data.entries[i].path[len] = 0
    data.entries[i].deadline = to_deadline(value)
    data.count = data.count + 1
  end
end

---@param path string
---@return number
M.get = function(path)
  if not initialized or not data then return 0 end

  local idx = find_entry(path)
  if not idx then return 0 end

  return to_score(data.entries[idx].deadline)
end

---@param path string
---@return boolean?
M.del = function(path)
  if not initialized or not data then return end
  local idx = find_entry(path)
  if not idx then return false end
  return evict(idx)
end

---@param n? number max results
---@return {path:string, score:number}[]
M.list = function(n)
  if not initialized or not data then return {} end

  n = n or data.count
  local results = {}

  for i = 0, data.count - 1 do
    results[#results + 1] = {
      path = ffi.string(data.entries[i].path),
      score = to_score(data.entries[i].deadline),
    }
  end

  table.sort(results, function(a, b) return a.score > b.score end)

  local slice_end = math.min(n, #results)
  local sliced = {}
  for i = 1, slice_end do
    sliced[i] = results[i]
  end
  return sliced
end

M.sync = function()
  if not initialized or not data then return end
  ffi.C.msync(data, MMAP_SIZE, ffi.C.MS_SYNC)
end

M.shutdown = function()
  if initialized and data then
    save_to_file()
    M.sync()
    ffi.C.munmap(data, MMAP_SIZE)
    data = nil
    initialized = false
  end
end

M.enable = function()
  if not M.init() then return end

  local group = api.nvim_create_augroup('u.frecency', { clear = true })

  api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function() M.shutdown() end,
  })

  api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(ev)
      local current_win = api.nvim_get_current_win()
      if api.nvim_win_get_config(current_win).relative ~= '' then return end
      M.visit_buf(ev.buf)
    end,
  })

  local timer = vim.uv.new_timer()
  timer:start(60000, 60000, vim.schedule_wrap(save_to_file))
end

M.disable = function()
  api.nvim_del_augroup_by_name('u.frecency')
  M.shutdown()
end

return M
