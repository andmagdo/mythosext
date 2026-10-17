

local BASE   = "https://scribblehub.com"
local logger = require("logger")

local ext = {
    id      = "scribblehub",
    name    = "scribblehub",
    site    = BASE,
    lang    = "en",
    version = "0.0.1",
}


-- first step: hope that you don't get cloudflared.

local seriesSortBy = {
    popularity = 1,
    favorites = 2,
    activity = 3,
    readers = 4,
    rising = 5
}

local seriesOrder = {
    daily = 1,
    weekly = 2,
    monthly = 3,
    alltime = 4
}

-- Httpget, taken from novelfire
local function http_get(url)
    logger.dbg("Scribblehub: http_get url=", url)
    local https    = require("ssl.https")
    local http     = require("socket.http")
    local ltn12    = require("ltn12")
    local sink     = {}
    local req      = url:match("^https") and https or http
    local ok, code = req.request {
        url     = url,
        sink    = ltn12.sink.table(sink),
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (Linux; Android 9; KOReader)",
            ["Accept"]     = "text/html,application/xhtml+xml,*/*;q=0.8",
            ["Referer"]    = BASE .. "/",
        },
        timeout = 30,
    }
    logger.dbg("Scribblehub: http_get code=", tostring(code), "ok=", tostring(ok))
    if not ok or code ~= 200 then
        logger.err("Scribblehub: http_get FAILED url=", url, "code=", tostring(code))
        if code == 403 then
            logger.err("Blocked by cloudflare")
        end
        return nil, code
    end
    local body = table.concat(sink)
    logger.dbg("Scribblehub: http_get body_len=", #body)
    return body
end

local function http_get_json(url)
    logger.dbg("Scribblehub: http_get_json url=", url)
    local body, err = http_get(url)
    if not body then
        logger.err("Scribblehub: http_get_json fetch failed:", tostring(err))
        return nil, err
    end
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok2, data = pcall(JSON.decode, body)
    if not ok2 then
        logger.err("Scribblehub: JSON decode error:", tostring(data))
        return nil, "json_error"
    end
    logger.dbg("Scribblehub: http_get_json decode ok, type=", type(data))
    return data
end
--


local function http_post(url)
    logger.dbg("Scribblehub: http_get url=", url)
    local https    = require("ssl.https")
    local http     = require("socket.http")
    local ltn12    = require("ltn12")
    local sink     = {}
    local req      = url:match("^https") and https or http

    local ok, code = req.request {
        url     = url,
        sink    = ltn12.sink.table(sink),
        method  = "POST",
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (Linux; Android 9; KOReader)",
            ["Accept"]     = "text/html,application/xhtml+xml,*/*;q=0.8",
            ["Referer"]    = BASE .. "/",
        },
        timeout = 30,
    }
    logger.dbg("Scribblehub: http_get code=", tostring(code), "ok=", tostring(ok))
    if not ok or code ~= 200 then
        logger.err("Scribblehub: http_get FAILED url=", url, "code=", tostring(code))
        if code == 403 then
            logger.err("Blocked by cloudflare")
        end
        return nil, code
    end
    local body = table.concat(sink)
    logger.dbg("Scribblehub: http_get body_len=", #body)
    return body
end




-- simple html parser I wrote

local function strFind(str, match, index)
    local tmp = str:find(match, index)
    if(tmp == nil) then
        return -1
    else
        return tmp
    end
end

local function innerHtml(str)
    local str = str:match("%>.+%<")
    return str:sub(2, #str - 1)
end

local function getText(str)
    local ret = str:gsub("%<.-%>", "")
    return ret
end

local function getAttribute(tag, attr)
    local tag = tag:match("%<.+%>")
    local attribute = tag:match(attr.."=.-[%s%>]")
    return attribute:sub(1+#(attr.."=\""),#attribute-2)
end

local function getTag(html, tag, attr, val, index) -- returns the tag's outerHTML and index at the end of the tag
    local index = index
    local checkString = ""
    local found = false
    local attrString = ""
    if (#attr > 0) then
        attrString = "%s"..attr.."=\"" ..
            val ..
            "\""      -- simple match of the class string, assuming that there is a string
    end
    index = strFind(html, "%<" .. tag, index)                        -- find the first instance of the tag

    while (not found and (index > -1)) do                            -- runs when has not been found, as well as while there are still new tags
        checkString = html:match("%<" .. tag .. ".-" .. "%>", index) -- grab that tag
        if (checkString:match(attrString)) then                     -- ensure that the class is present
            found = true
        end
        index = strFind(html, "%<" .. tag, index) -- find the next instance of the tag
    end

    if (not found) then
        --logger.err("Tag not found")
        return { "", -1 }; -- return if there isn't a matching tag
    end

    local startIndex = index

    local tagString = ""
    while (index > -1) do
        tagName = html:match("%<" .. ".-" .. "[%s%>]", index)
        tagName = tagName:sub(2, #tagName - 1)
        if (tagName:sub(1, 1) == "/") then
            tagString = tagString:sub(1, #tagString - #tagName + 1)
        else
            tagString = tagString .. tagName
        end
        index = strFind(html,"%>",index)
        if (#tagString == 0) then
            return { html:sub(startIndex, index), index }
        end
        index = index + 1
    end
    --logger.err("End tag not found")
    return { "", -1 };
end


local function getTags(html, tag, attr, val)
    local ret = {}
    local index = 0
    while (index ~= -1) do
        local out = getTag(html, tag, attr, val, index);
        if (out[2] == -1) then
            return ret
        end
        ret[#ret + 1], index = out[1], out[2]
    end
end

local function getFirstTag(html, tag, attr, val)
    return getTag(html, tag, attr, val,0)
end
--


local function getNovelList(div)
    local list = getTags(div[1], "div", "class", "search_main_box")
    local novels = {}
    for listing in list do
        local imageLink = getAttribute(getFirstTag(listing, "img", "", "")[1], "src")
        local titlediv = getFirstTag(listing, "div", "class", "search_title")[1]
        local titlelink = getFirstTag(titlediv, "a", "", "")[1]
        local title = getText(titlelink)
        local novelLink = getAttribute(titlelink, "href")
        novels:insert({ name = title, path = novelLink, cover = imageLink })
    end

    return novels
end


function ext:popularNovels(page, options)
    page = page or 1
    local url = BASE .. "/series-ranking/" ..
    "?sort=" .. seriesSortBy.popularity .. "&order=" .. seriesOrder.daily .. "&pg=" .. page
    local html, err = http_get(url)
    local novels = {}
    if (not html) then
        logger.err("Scribblehub: popularNovels fetch failed:", tostring(err))
        return {novels = novels}
    end
    local div = getFirstTag(html, "div", "class", "wi_fic_wrap")
    novels = getNovelList(div)
    return { novels = novels }
end

function ext:searchNovels(term, page)
    page = page or 1
    local url = BASE .. "/series-finder/" .. "?sf=1" .. "&sh="..term .. "&pg=" .. page
    local html, err = http_get(url)
    local novels = {}
    if (not html) then
        logger.err("Scribblehub: search fetch failed:", tostring(err))
        return {novels = novels}
    end
    local div = getFirstTag(html, "div", "class", "error_msg_profile sf_results")
    novels = getNovelList(div)
    return { novels = novels }
end

function ext:parseNovel(path)

    return { name = "", path = path, chapters = {}, totalPages = 1 }
end

function ext:parseChapter(path)
    return "<p></p>"
end

return ext
