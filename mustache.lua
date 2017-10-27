
--full-spec mustache parser and bytecode-based renderer.
--Written by Cosmin Apreutesei. Public Domain.

local push = table.insert
local pop = table.remove
local _ = string.format

--for a string, return a function that given a byte index in the string
--returns the line and column numbers corresponding to that index.
local function textpos(s)
	--collect char indices of all the lines in s, incl. the index at #s + 1
	local t = {}
	for i in s:gmatch'()[^\r\n]*\r?\n?' do
		t[#t+1] = i
	end
	assert(#t >= 2)
	return function(i)
		--do a binary search in t to find the line
		assert(i > 0 and i <= #s + 1)
		local min, max = 1, #t
		while true do
			local k = math.floor(min + (max - min) / 2)
			if i >= t[k] then
				if k == #t or i < t[k+1] then --found it
					return k, i - t[k] + 1
				else --look forward
					min = k
				end
			else --look backward
				max = k
			end
		end
	end
end

--raise an error for something that happened at s[i], so that position in
--file (line, column) can be printed. if i is nil, eof is assumed.
--if s is nil, no position info is printed with the error.
local function raise(s, i, err, ...)
	err = _(err, ...)
	local where
	if s then
		if i then
			local pos = textpos(s)
			local line, col = pos(i)
			where = _('line %d, col %d', line, col)
		else
			where = 'eof'
		end
		err = _('error at %s: %s.', where, err)
	else
		err = _('error: %s.', err)
	end
	error(err, 2)
end

local function trim(s) --fast trim from glue
	local from = s:match'^%s*()'
	return from > #s and '' or s:match('.*%S', from)
end

--escape a string so that it can be matched literally inside a pattern.
local function escape(s) --from glue
	return s:gsub('%%','%%%%'):gsub('%z','%%z')
		:gsub('([%^%$%(%)%.%[%]%*%+%-%?])', '%%%1')
end

--calls parse(i, j, token_type, ...) for each token in s. i and j are such
--that s:sub(i, j) gives the unparsed token. tokens can be 'text' and 'var'.
--var tokens get more args: (name, modifier, d1, d2, i1). name is unparsed.
--modifiers can be '&' ,'#', '^', '>', '/'. d1 and d2 are the current set
--delimiters (needed for lambdas). i1 is such that s:sub(i, i1) gives the
--indent of a standalone section (for partials). set delimiters and comments
--are dealt with in the tokenizer.
local function tokenize(s, parse, d1, d2)
	local d1 = d1 or '{{' --start delimiter
	local d2 = d2 or '}}' --end delimiter
	local patt, patt2
	local function setpatt()
		patt = '()\r?\n?()[ \t]*()'..
			escape(d1)..'([!&#%^/>=]?)().-()'..
			escape(d2)..'()[ \t]*()\r?\n?()'
		--secondary pattern for matching the special case `{{{...}}}`
		patt2 = d1 == '{{' and d2 == '}}' and
			'()\r?\n?()[ \t]*(){{({)().-()}}}()[ \t]*()\r?\n?()'
	end
	setpatt()
	local i = 1
	local was_newline = true
	while i <= #s do
		local patt = patt2 and s:match('{{{?', i) == '{{{' and patt2 or patt
		local i1, i2, i3, mod, k1, k2, j, j1, j2 = s:match(patt, i)
		if i1 then
			if mod == '{' then mod = '&' end --merge `{` and `&` cases
			local starts_alone = i1 < i2 or (i1 == i and was_newline)
			local ends_alone = j1 < j2 or j2 == #s + 1
			local can_be_standalone = mod ~= '' and mod ~= '&'
			local standalone = can_be_standalone and starts_alone and ends_alone
			local p1, p2 --the char positions delimiting the `{{...}}` token
			if standalone then
				p1 = i2 --first char of the line
				p2 = j2 --first char of the next line
			else
				p1 = i3 --where `{{` starts
				p2 = j  --1st char after `}}`
			end
			if p1 > i then --there's text before `{{`
				parse(i, p1-1, 'text')
			end
			if mod ~= '!' then --not a comment (we skip those)
				local var = trim(s:sub(k1, k2-1))
				if var == '' then
					raise(s, k1, 'empty var')
				end
				if mod == '=' then --set delimiter
					d1, d2 = var:match'^%s*([^%s]+)%s+([^%s=]+)%s*='
					d1 = d1 and trim(d1)
					d2 = d2 and trim(d2)
					if not d1 or d1 == '' or d2 == '' then
						raise(s, k1, 'invalid set delimiters')
					end
					setpatt()
				else
					parse(p1, p2-1, 'var', var, mod, d1, d2, i3-1)
				end
			end
			i = p2 --advance beyond the var
			was_newline = j1 < j2
		else --not matched, so it's text till the end then
			parse(i, #s, 'text')
			i = #s + 1
		end
	end
end

local function parse_var(var) --parse 'a.b.c' to {'a', 'b', 'c'}
	if var == '.' or not var:find('.', 1, true) then
		return var --simple var, leave it
	end
	local path = {}
	for s in var:gmatch'[^%.]+' do --split by `.`
		path[#path+1] = s
	end
	return path
end

local cache = setmetatable({}, {__mode = 'kv'}) --{template -> prog} cache

--compile a template to a program that can be interpreted with render().
--the program is a list of commands with varargs.
--  'text',   i, j          : constant text, render it as is
--  'html',   i, j, var     : substitute var and render it as html, escaped
--  'string', i, j, var     : substitute var and render it as is, unescaped
--  'iter',   i, j, var, nextpc, ti, tj, d1, d2 : section (*)
--  'ifnot',  i, j, var, nextpc, ti, tj, d1, d2 : inverted section (*)
--  'end'     i, j          : end of section or inverted section
--  'render', i, j, partial, i1 : render partial (**)
--(*) for sections, nexpc is the index in the program where the next command
--after the section is (for jumping to it); ti and tj are such that
--template:(ti, tj) gives the unparsed text inside the section (for lambdas),
--and d1 and d2 are the current set delimiters (for lambdas).
--(**) for partials, i1 is such that template:sub(i, i1) gives the
--indent of the partial which must be applied to the lines of the result.
local function compile(template, d1, d2)
	if type(template) == 'table' then --already compiled
		return template
	end
	assert(not d1 == not d2, 'error: only one delimiter specified')
	local key = (d1 or '')..'\0'..(d2 or '')..'\0'..template
	local prog = cache[key]
	if prog then
		return prog
	end
	prog = {template = template}
	cache[key] = prog

	local function cmd(...)
		for i=1,select('#',...) do
			prog[#prog+1] = select(i,...)
		end
	end

	local sec_stack = {} --stack of section names
	local arg_stack = {} --stack of (pi_nexpc, pi_j)

	tokenize(template, function(i, j, what, var, mod, d1, d2, i1)
		if what == 'text' then
			cmd('text', i, j)
		elseif what == 'var' then
			if mod == '' then
				cmd('html', i, j, parse_var(var))
			elseif mod == '&' then --no escaping
				cmd('string', i, j, parse_var(var))
			elseif mod == '#' or mod == '^' then --section
				local c = mod == '#' and 'iter' or 'ifnot'
			 	cmd(c, i, j, parse_var(var), 0, j+1, 0, d1, d2)
				push(sec_stack, var)     --unparsed section name
				push(arg_stack, #prog-4) --index in prog of yet-unknown nexpc
				push(arg_stack, #prog-2) --index in prog of yet-unknown tj
			elseif mod == '/' then --close section
				local pi_tj     = pop(arg_stack)
				local pi_nextpc = pop(arg_stack)
				local section   = pop(sec_stack)
				if section ~= var then
					local expected = section and _('{{/%s}}', section)
						or 'no section open'
					raise(template, i, '%s but found {{/%s}}', expected, var)
				end
				cmd('end', i, j)
				prog[pi_nextpc] = #prog + 1 --set nextpc on the iter cmd
				prog[pi_tj] = i-1 --set the end position of the inner text
			elseif mod == '>' then --partial
				cmd('render', i, j, var, i1)
			end
		end
	end, d1, d2)

	if #sec_stack > 0 then
		local sections = table.concat(sec_stack, ', ')
		raise(template, nil, 'unclosed sections: %s', sections)
	end

	return prog
end

local function dump(prog, d1, d2, print) --dump bytecode
	print = print or _G.print
	prog = compile(prog, d1, d2)
	local pp = require'pp'
	local function var(var)
		return type(var) == 'table' and table.concat(var, '.') or var
	end
	local function text(i, j)
		local s = pp.format(prog.template:sub(i, j))
		if #s > 50 then
			s = s:sub(1, 50-3)..'...'
		end
		return s
	end
	local pos = textpos(prog.template)
	local pc = 1
	print'  IDX  #  LN:COL  PC  CMD    ARGS'
	while pc <= #prog do
		local cmd = prog[pc]
		local i = prog[pc+1]
		local j = prog[pc+2]
		local line, col = pos(i)
		local s
		if cmd == 'text' then
			s = text(i, j)
		elseif cmd == 'html' or cmd == 'string' then
			s = _('%-12s', var(prog[pc+3]))
			pc = pc + 1
		elseif cmd == 'render' then
			s = _('%-12s i1: %d', var(prog[pc+3]), prog[pc+4])
			pc = pc + 2
		elseif cmd == 'iter' or cmd == 'ifnot' then
			local name, nextpc, ti, tj, d1, d2 = unpack(prog, pc+3, pc+8)
			s = _('%-12s nextpc: %d, delim: %s %s, text: %s',
					var(name), nextpc, d1, d2, text(ti, tj))
			pc = pc + 6
		elseif cmd == 'end' then
			s = ''
		else
			assert(false)
		end
		print(_('%5d %2d %3d:%3d %3d  %-6s %s', i, j-i+1, line, col, pc, cmd, s))
		pc = pc + 3
	end
end

local escapes = { --from mustache.js
	['&']  = '&amp;',
	['<']  = '&lt;',
	['>']  = '&gt;',
	['"']  = '&quot;',
	["'"]  = '&#39;',
	['/']  = '&#x2F;',
	['`']  = '&#x60;', --attr. delimiter in IE
	['=']  = '&#x3D;',
}
local function escape_html(v)
	return v:gsub('[&<>"\'/`=]', escapes) or v
end

--check if a value is considered valid in a way compatible with mustache.js.
local function istrue(v)
	if type(v) == 'table' then
		return next(v) ~= nil
	else
		return v and v ~= '' and v ~= 0 and v ~= '0' or false
	end
end

--check if a value is considered a valid list.
local function islist(t)
	return type(t) == 'table' and #t > 0
end

local function render(prog, view, getpartial, write, d1, d2, escape_func)

	prog = compile(prog, d1, d2)

	if type(getpartial) == 'table' then --partials table given, build getter
		local partials = getpartial
		getpartial = function(name)
			return partials[name]
		end
	end

	local outbuf
	if not write then --writer not given, do buffered output
		outbuf = {}
		write = function(s)
			outbuf[#outbuf+1] = s
		end
	end

	local function out(s)
		if s == nil then return end
		write(tostring(s))
	end

	local escape = escape_func or escape_html

	local ctx_stack = {}

	local function lookup(var, i) --lookup a var in the context hierarchy
		local val = ctx_stack[i][var]
		if val ~= nil then --var found
			return val
		end
		if i == 1 then --top context
			return nil
		end
		return lookup(var, i-1) --check parent (tail call)
	end

	--get the value of a var from the view
	local function resolve(var)
		if #ctx_stack == 0 then
			return nil --no view
		end
		local val
		local ctx = ctx_stack[#ctx_stack]
		if var == '.' then --"this" var
			val = ctx
		elseif type(var) == 'table' then --'a.b.c' parsed as {'a', 'b', 'c'}
			val = lookup(var[1], #ctx_stack)
			for i=2,#var do
				if not istrue(val) then --falsey values resolve to ''
					val = nil
					break
				end
				if type(val) ~= 'table' then
					raise(nil, nil, 'table expected for field "%s" but got %s',
						var[i], type(val))
				end
				val = val[var[i]]
			end
		else --simple var
			val = lookup(var, #ctx_stack)
		end
		return val
	end

	local function run_section_lambda(lambda, ti, tj, d1, d2)
		local text = prog.template:sub(ti, tj)
		local view = ctx_stack[#ctx_stack]
		local function render_lambda(text)
			return render(text, view, getpartial, nil, d1, d2)
		end
		return lambda(text, render_lambda)
	end

	local function render_lambda_result(val, d1, d2)
		if type(val) == 'string' and val:find('{{', 1, true) then
			local view = ctx_stack[#ctx_stack]
			val = render(val, view, getpartial, nil, d1, d2)
		end
		return val
	end

	local function check_value_lambda(val)
		if type(val) == 'function' then
			val = render_lambda_result((val()))
		end
		return val
	end

	local function indent(s, indent)
		return s:gsub('([^\r\n]+\r?\n?)', indent..'%1')
	end

	local pc = 1 --program counter
	local function pull()
		local val = prog[pc]
		pc = pc + 1
		return val
	end

	local iter_stack = {}
	local HASH, COND = {}, {} --dummy iter objects for comparison

	local function iter(val, nextpc, ti, tj, d1, d2)
		if islist(val) then --list value, iterate it
			push(iter_stack, {list = val, n = 1, pc = pc})
			push(ctx_stack, val[1]) --non-empty list so val[1] is never nil
		else
			if type(val) == 'table' then --hashmap, set as context
				push(iter_stack, HASH)
				push(ctx_stack, val)
			else --conditional section, don't push a context
				push(iter_stack, COND)
			end
		end
	end

	local function enditer()
		local iter = iter_stack[#iter_stack]
		if iter.n then --list
			iter.n = iter.n + 1
			if iter.n <= #iter.list then --loop
				ctx_stack[#ctx_stack] = iter.list[iter.n]
				pc = iter.pc
				return
			end
		end
		pop(iter_stack)
		if iter ~= COND then
			pop(ctx_stack)
		end
	end

	push(ctx_stack, view)

	while pc <= #prog do
		local cmd = pull()
		local i = pull()
		local j = pull()
		if cmd == 'text' then
			out(prog.template:sub(i, j))
		elseif cmd == 'html' then
			local val = check_value_lambda(resolve(pull()))
			if val ~= nil then
				out(escape(tostring(val)))
			end
		elseif cmd == 'string' then
			out(check_value_lambda(resolve(pull())))
		elseif cmd == 'iter' or cmd == 'ifnot' then
			local var = pull()
			local nextpc = pull()
			local ti = pull()
			local tj = pull()
			local d1 = pull()
			local d2 = pull()
			local val = resolve(var)
			if type(val) == 'function' then
				val = run_section_lambda(val, ti, tj, d1, d2)
				if cmd == 'ifnot' then --lambdas on inv. sections must be truthy
					val = nil
				end
				val = render_lambda_result(val, d1, d2)
				if istrue(val) then
					out(val)
				end
				pc = nextpc --section is done
			else
				if cmd == 'ifnot' then
					val = not istrue(val)
				end
				if istrue(val) then --valid section value, iterate it
					iter(val, nextpc)
				else
					pc = nextpc --skip section entirely
				end
			end
		elseif cmd == 'end' then
			enditer() --loop back or pop iteration
		elseif cmd == 'render' then
			local partial = getpartial(pull())
			local i1 = pull()
			if partial then
				local view = ctx_stack[#ctx_stack]
				if i1 >= i then
					local spaces = prog.template:sub(i, i1)
					partial = indent(partial, spaces)
				end
				render(partial, view, getpartial, write)
			end
		end
	end

	if outbuf then
		return table.concat(outbuf)
	end
end

if not ... then require'mustache_test' end

return {
	compile = compile,
	render = render,
	dump = dump,
}