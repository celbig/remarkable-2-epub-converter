--[[
dev/simple.lua — dump the whole Pandoc AST for inspection.

    pandoc test.epub --lua-filter=dev/simple.lua -t native -o /dev/null 2>dump.log

Pandoc does not put the filter's own directory on package.path, so logging.lua
sitting next to this file is not findable by a bare require; derive the path
from PANDOC_SCRIPT_FILE instead of assuming the filter is run from its own
directory.
]]

package.path = PANDOC_SCRIPT_FILE:gsub('[^/\\]*$', '?.lua') .. ';' .. package.path

local logging = require 'logging'

function Pandoc(doc)
    logging.temp('pandoc', doc)
end
