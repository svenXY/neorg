local docgen = {}

docgen.output_dir = "wiki"

pcall(vim.fn.mkdir, docgen.output_dir)

local scan = require("plenary.scandir")

require("neorg").setup({
    load = {
        ["core.integrations.treesitter"] = {},
    },
})

-- Start neorg
neorg.org_file_entered(false)

-- Extract treesitter utility functions provided by Neorg and nvim-treesitter.ts_utils
local ts = neorg.modules.get_module("core.integrations.treesitter")
local ts_utils = ts.get_ts_utils()

-- Store all parsed modules in this variable
local modules = {}

docgen.find_modules = function()
    local path = vim.fn.getcwd()
    local neorg_modules = "lua/neorg/modules"

    return scan.scan_dir(path .. "/" .. neorg_modules, { search_pattern = "module.lua$" })
end

docgen.get_buf_from_file = function(path)
    local uri = vim.uri_from_fname(path)
    local buf = vim.uri_to_bufnr(uri)

    return buf
end

docgen.get_module_top_comment = function(path)
    local buf = docgen.get_buf_from_file(path)
    local node = ts.get_first_node_recursive("comment", { buf = buf, ft = "lua" })

    if not node then
        return
    end

    -- Verify if it's the first line
    local start_row = ts_utils.get_node_range(node)
    if start_row ~= 0 then
        return
    end

    local comment = ts_utils.get_node_text(node, buf)

    -- Stops execution if it's not a multiline comment
    if not comment[1] == "--[[" or not comment[#comment] == "--]]" then
        return
    end

    -- Removes first and last braces
    table.remove(comment, 1)
    table.remove(comment, #comment)

    return buf, comment
end

docgen.get_module_queries = function(buf, query)
    vim.api.nvim_set_current_buf(buf)

    return vim.treesitter.parse_query("lua", query)
end

docgen.generate_md_file = function(buf, path, comment)
    local module = dofile(path)
    modules[module.name] = module

    local structure = {
        "",
        "## Usage",
        "### How to Apply",
        function()
            local core_defaults = modules["core.defaults"]

            if not core_defaults then
                return
            end

            if
                not vim.tbl_isempty(vim.tbl_filter(function(elem)
                    return elem == module.name
                end, core_defaults.config.public.enable or {}))
            then
                return {
                    "- This module is already present in the [`core.defaults`](https://github.com/nvim-neorg/neorg/wiki/"
                        .. core_defaults.filename
                        .. ") metamodule.",
                    "  You can load the module with:",
                    "  ```lua",
                    '  ["core.defaults"] = {},',
                    "  ```",
                    "  In your Neorg setup.",
                }
            end
        end,
        "- To manually load the module, place this code in your Neorg setup:",
        "  ```lua",
        '  ["' .. module.name .. '"] = {',
        "     config = { -- Note that this table is optional and doesn't need to be provided",
        "         -- Configuration here",
        "     }",
        "  }",
        "  ```",
        "  Consult the [configuration](###Configuration) section to see how you can configure `"
            .. module.name
            .. "` to your liking.",
        "",
        "## Developer Usage",
        "### Examples",
        {
            query = [[
                (variable_declaration
                    (variable_declarator
                        (field_expression) @_field
                        (#eq? @_field "module.examples")
                    )
                ) @declaration
            ]],

            callback = function(main_query)
                if vim.tbl_isempty(module.examples) then
                    return { "None Provided" }
                end

                local tree = vim.treesitter.get_parser(buf, "lua"):parse()[1]
                local result = {}
                local index = 0

                for _, variable_declaration in main_query:iter_captures(tree:root(), buf) do
                    if variable_declaration:type() == "variable_declaration" then
                        local query = vim.treesitter.parse_query(
                            "lua",
                            [[
                            (table
                                (field
                                    [
                                        (identifier)
                                        (string)
                                    ] @identifier
                                    (function_definition
                                        (parameters)
                                    )
                                )
                            )
                        ]]
                        )

                        for id, node in query:iter_captures(variable_declaration, buf) do
                            local capture = query.captures[id]

                            if capture == "identifier" then
                                index = index + 1
                                local identifier_text = ts.get_node_text(node)
                                identifier_text = identifier_text:gsub("[\"'](.+)[\"']", "%1") or identifier_text

                                result[index] = {
                                    "#### " .. identifier_text,
                                    "```lua",
                                }

                                local start_node = node:next_named_sibling()

                                if not start_node then
                                    table.insert(result[index], "-- empty code block")
                                end

                                local text = ts_utils.get_node_text(start_node)

                                -- Remove the function() and "end" keywords
                                table.remove(text, 1)
                                table.remove(text)

                                local start = vim.api.nvim_strwidth(text[1]:match("^%s*")) + 1

                                for i = 1, #text do
                                    text[i] = text[i]:sub(start)
                                end

                                vim.list_extend(result[index], text)

                                table.insert(result[index], "```")
                                table.insert(result[index], "")
                            end
                        end
                    end
                end

                return vim.tbl_flatten(result)
            end,
        },
        "",
        "## Extra Info",
        "### Version",
        "The `" .. module.name .. "` module is currently at version **" .. module.public.version .. "**.",
        "For reference the current Neorg version is **" .. neorg.configuration.version .. "**.",
        "",
        "### Requires",
        function()
            local required = module.setup().requires

            if not required or vim.tbl_isempty(required) or not modules[required[1]] then
                return { "This module does not require any other modules to operate." }
            end

            local ret = {}

            for _, name in ipairs(required) do
                if modules[name] and modules[name].filename then
                    ret[#ret + 1] = "- [`"
                        .. name
                        .. "`](https://github.com/nvim-neorg/neorg/wiki/"
                        .. modules[name].filename
                        .. ") - "
                        .. (modules[name].short_description or "no description")
                else
                    ret[#ret + 1] = "- `" .. name .. "` - undocumented module"
                end
            end

            return ret
        end,
    }

    if not comment or #comment == 0 then
        return
    end

    local oldkey
    local arguments = {}

    for i, line in ipairs(comment) do
        if line:match("^%s*---$") then
            comment = vim.list_slice(comment, i + 1)
            break
        end

        local key, value = line:match("^%s*([%w%s]+)%:%s+(.+)$")

        if key and value then
            key = key:lower():gsub("%s", "_")
            arguments[key] = value
            oldkey = key
        elseif not line:match("^%s*$") and oldkey then
            arguments[oldkey] = arguments[oldkey] .. " " .. vim.trim(line)
        end
    end

    if not arguments.file then
        return
    end

    -- Populate the module with some extra info
    module.filename = arguments.file
    module.short_description = arguments.short_description
    module.description = arguments.description

    -- Construct the desired filename
    local output_filename = module.filename .. ".md"

    -- Generate structure
    for _, item in ipairs(structure) do
        if type(item) == "string" then
            table.insert(comment, item)
        elseif type(item) == "table" then
            local query = docgen.get_module_queries(buf, item.query)

            if query then
                local ret = item.callback(query)

                for _, str in ipairs(ret) do
                    table.insert(comment, str)
                end
            end
        elseif type(item) == "function" then
            vim.list_extend(comment, item() or {})
        end
    end

    local output_buffer = vim.api.nvim_create_buf(false, false)
    local output_path = vim.fn.getcwd() .. "/" .. docgen.output_dir .. "/" .. output_filename
    vim.api.nvim_buf_set_name(output_buffer, output_path)
    vim.api.nvim_buf_set_lines(output_buffer, 0, -1, false, comment)
    vim.api.nvim_buf_call(output_buffer, function()
        vim.cmd("write!")
    end)
    vim.api.nvim_buf_delete(output_buffer, { force = true })
end

local files = docgen.find_modules()

for i = 1, 2 do
    for _, file in ipairs(files) do
        local buf, comment = docgen.get_module_top_comment(file)

        if comment then
            docgen.generate_md_file(buf, file, comment)
        end
    end
end

return docgen
