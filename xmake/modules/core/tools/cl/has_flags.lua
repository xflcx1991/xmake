--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, Xmake Open Source Community.
--
-- @author      ruki
-- @file        has_flags.lua
--

-- imports
import("core.language.language")
import("core.cache.global_detectcache")
import("core.tools.cl.check_knownargs")
import("private.tools.vstool")

-- get the argument list of this driver, and whether it knows /options:strict
--
-- the option list is fetched once per program+version and cached. @see
-- https://github.com/xmake-io/xmake/issues/7610
function _get_arglist(opt)
    local key = "core.tools.cl.has_flags"
    local flagskey = opt.program .. "_" .. (opt.programver or "")
    local allflags = global_detectcache:get2(key, flagskey)
    if not allflags then
        allflags = {}
        local arglist = vstool.iorunv(opt.program, {"-?"}, {envs = opt.envs})
        if arglist then
            for arg in arglist:gmatch("(/[%-%a%d]+)%s+") do
                allflags[arg:gsub("/", "-")] = true
            end
            -- the class above stops at ':', so /options:strict can only ever be
            -- keyed as "-options" here. the question of whether the driver has it
            -- at all is asked of the text instead, and remembered beside the list.
            -- unlike a flag name, this key cannot collide with one: every flag key
            -- above begins with '-' after the gsub.
            allflags._options_strict = arglist:find("options:strict", 1, true) ~= nil
        end
        global_detectcache:set2(key, flagskey, allflags)
        global_detectcache:save()
    end
    return allflags
end

-- attempt to check it from the argument list
function _check_from_arglist(flags, opt)
    return _get_arglist(opt)[flags[1]:gsub("/", "-")]
end

-- get extension
function _get_extension(opt)
    return opt.flagkind == "cxxflags" and ".cpp" or (table.wrap(language.sourcekinds()[opt.toolkind or "cc"])[1] or ".c")
end

-- get the "this driver does not have that flag" output from cl
--
-- two codes say it, and they are the only two ways cl can:
--
--   cl : Command line warning D9002 : ignoring unknown option '-xx'
--       the driver has no such option and no /options:strict to make it an error,
--       so cl drops it, compiles the stub and exits 0. the text is the only signal
--       that answer exists on.
--   cl : Command line error D8043 : unknown option '-xx'
--       the same answer once /options:strict is in effect, and it arrives with a
--       non-zero exit, so vstool.iorunv raises before we are reached. matched so
--       that one rule covers both regimes.
--
-- every other code at exit 0 is not an answer about support:
--
--   <src> : warning C5072: ASAN enabled without debug information emission ...
--       the frontend's own warning, and what this filter exists for. cl prints it
--       whenever -fsanitize=address arrives on a line with no debug-info flag
--       (-Zi/-ZI/-Z7), which is how the probe line always looks once the asan flag
--       leaks into sysflags -- so every probe of every other flag answers with it.
--   D9014 / D9025 / D9041 / D8021 : bad VALUES of options the driver does have,
--       where cl assumes a default and compiles anyway. that is support.
--
-- cl also echoes the source filename on every compile (-nologo only drops the
-- banner), so that line is filtered out too.
--
-- measured on cl 14.51 through vstool.iorunv: both codes above land in outdata and
-- errdata is empty, because vstool redirects cl's diagnostics through
-- VS_UNICODE_OUTPUT rather than its stderr. matching the code rather than message
-- words also keeps this working on a localized cl.
--
function _get_output(outdata, sourcefile)
    local filename = path.filename(sourcefile)
    local output = {}
    for _, line in ipairs((outdata or ""):split("\n", {plain = true})) do
        line = line:rtrim()
        if #line > 0 and not line:endswith(filename)
            and (line:find("D9002", 1, true) or line:find("D8043", 1, true)) then
            table.insert(output, line)
        end
    end
    return #output > 0 and table.concat(output, "\n") or nil
end

-- try running to check flags
function _check_try_running(flags, opt)

    -- make an stub source file
    local snippet = opt.snippet or "int main(int argc, char** argv)\n{return 0;}\n"
    local sourcefile = os.tmpfile("cl_has_flags:" .. snippet) .. _get_extension(opt)
    if not os.isfile(sourcefile) then
        io.writefile(sourcefile, snippet)
    end

    -- check it
    local errors = nil
    return try  {   function ()
                        local tmpdir = os.tmpdir()
                        local nuldev = os.nuldev()
                        local tmpfile
                        if not is_host("windows") then
                            tmpfile = os.tmpfile()
                            nuldev = tmpfile
                        end
                        local argv = table.join("-c", "-nologo")

                        -- put /options:strict on the probe line where the driver has it,
                        -- so an unsupported flag answers with a non-zero exit instead of
                        -- text we have to interpret. it is VS 2022 17.0+ only, and this
                        -- module is inherited by icl and ifort, so it is asked of the
                        -- driver's own option list rather than assumed: on a driver
                        -- without it the option is itself an unknown flag, and the D9002
                        -- that earns would answer "unsupported" for every probe there is.
                        --
                        -- an unanswered question (a -? that fails) means no strict, which
                        -- leaves the D9002 text scan above doing the work on its own.
                        if try { function () return _get_arglist(opt)._options_strict end } then
                            table.insert(argv, "-options:strict")
                        end

                        local outdata = vstool.iorunv(opt.program, table.join(argv, flags, "-Fo" .. nuldev, sourcefile),
                                            {envs = opt.envs, curdir = tmpdir}) -- we need to switch to tmpdir to avoid generating some tmp files, e.g. /Zi -> vc140.pdb
                        if tmpfile then
                            os.tryrm(tmpfile)
                        end
                        local errs = _get_output(outdata, sourcefile)
                        if errs then
                            return false, errs
                        end
                        return true
                    end,
                    catch { function (errs) errors = errs end }
                }, errors
end

-- has_flags(flags)?
--
-- @param opt   the argument options, e.g. {toolname = "", program = "", programver = "", toolkind = "[cc|cxx|ld|ar|sh|gc|rc|dc|mm|mxx]"}
--
-- @return      true or false
--
function main(flags, opt)

    -- attempt to check it from the argument list
    opt = opt or {}
    if not opt.tryrun then
        if check_knownargs(flags) then
            return true
        end
        if _check_from_arglist(flags, opt) then
            return true
        end
    end

    -- try running to check it
    return _check_try_running(flags, opt)
end

