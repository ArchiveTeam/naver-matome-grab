dofile("table_show.lua")
dofile("urlcode.lua")
JSON = (loadfile "JSON.lua")()
local urlparse = require("socket.url")
local http = require("socket.http")

local item_value = os.getenv('item_value')
local item_type = os.getenv('item_type')
local item_dir = os.getenv('item_dir')
local warc_file_base = os.getenv('warc_file_base')

local item_value_normalized = string.lower(urlparse.unescape(item_value))

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false

local done_tags = false

local discovered = {}
discovered["profile:" .. item_value] = true

local post_ids = {}

for ignore in io.open("ignore-list", "r"):lines() do
  downloaded[ignore] = true
end

for ignore in io.open("ignore-item-list", "r"):lines() do
  discovered[ignore] = true
end

load_json_file = function(file)
  if file then
    return JSON:decode(file)
  else
    return nil
  end
end

discover_item = function(type_, name, tries)
  if tries == nil then
    tries = 0
  end
  name = urlparse.escape(urlparse.unescape(name)) -- normalize
  item = type_ .. ':' .. name
  if discovered[item] then
    return true
  end
  io.stdout:write("Discovered item " .. item .. ".\n")
  io.stdout:flush()
  local body, code, headers, status = http.request(
    "http://blackbird-amqp.meo.ws:23038/navermatome-np2bf5h0b8xhv7s8gplh/",
    item
  )
  if code == 200 or code == 409 then
    discovered[item] = true
    return true
  elseif code == 404 then
    io.stdout:write("Project key not found.\n")
    io.stdout:flush()
  elseif code == 400 then
    io.stdout:write("Bad format.\n")
    io.stdout:flush()
  else
    io.stdout:write("Could not queue discovered item. Retrying...\n")
    io.stdout:flush()
    if tries == 10 then
      io.stdout:write("Maximum retries reached for sending discovered item.\n")
      io.stdout:flush()
    else
      os.execute("sleep " .. math.pow(2, tries))
      return discover_item(type_, name, tries + 1)
    end
  end
  abortgrab = true
  return false
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

allowed = function(url, parenturl)
  if string.match(urlparse.unescape(url), "[<>\\%*%$;%^%[%],%(%){}]")
    or string.match(url, "^https?://matome%.naver%.jp/report/abuse")
    or not string.match(url, "^https?://[^/]*naver%.jp/") then
    return false
  end

  local tested = {}
  for s in string.gmatch(url, "([^/]+)") do
    if tested[s] == nil then
      tested[s] = 0
    end
    if tested[s] == 6 then
      return false
    end
    tested[s] = tested[s] + 1
  end

  if string.match(url, "^https?://[^/]*img%.naver%.jp/")
    and item_type ~= "topic" then
    return true
  end

  local match = string.match(url, "^https?://matome%.naver%.jp/topic/([^/%?&]+)$")
  if match then
    discover_item("topic", match)
  end

  match = string.match(url, "^https?://matome%.naver%.jp/mymatome/([^/%?&]+)$")
  if not match then
    match = string.match(url, "^https?://matome%.naver%.jp/profile/([^/%?&]+)$")
  end
  if match then
    discover_item("profile", match)
  end

  if (
      string.match(url, "^https?://matome%.naver%.jp/odai/[0-9]+$")
      or string.match(url, "^https?://matome%.naver%.jp/feed/mymatome/[a-zA-Z0-9]+$")
    )
    and item_type == "profile"
    and parenturl
    and not string.match(parenturl, "^https?://matome%.naver%.jp/odai/[0-9]+") then
    post_ids[string.match(url, "([a-zA-Z0-9]+)$")] = true
  end

  for s in string.gmatch(url, "([^/%?&]+)") do
    if string.lower(urlparse.unescape(s)) == item_value_normalized then
      return true
    end
  end

  if url == "https://matome.naver.jp/api/user/tag/list" then
    return true
  end

  for s in string.gmatch(url, "([a-zA-Z0-9]+)") do
    if post_ids[s] then
      return true
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  local html = urlpos["link_expect_html"]

  if item_type == "topic"
    or string.match(url, "^https?://static%.line%-scdn%.net/") then
    return false
  end

  if (downloaded[url] ~= true and addedtolist[url] ~= true)
    and (allowed(url, parent["url"]) or html == 0) then
    addedtolist[url] = true
    return true
  end
  
  return false
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  
  downloaded[url] = true

  local function check(urla)
    local origurl = url
    local url = string.match(urla, "^([^#]+)")
    local url_ = string.match(url, "^(.-)%.?$")
    url_ = string.gsub(url_, "&amp;", "&")
    url_ = string.match(url_, "^(.-)%s*$")
    url_ = string.match(url_, "^(.-)%??$")
    url_ = string.match(url_, "^(.-)&?$")
    if (downloaded[url_] ~= true and addedtolist[url_] ~= true)
      and allowed(url_, origurl) then
      table.insert(urls, { url=url_ })
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (string.match(newurl, "^https?:\\?/\\?//?/?")
        or string.match(newurl, "^[/\\]")
        or string.match(newurl, "^%./")
        or string.match(newurl, "^[jJ]ava[sS]cript:")
        or string.match(newurl, "^[mM]ail[tT]o:")
        or string.match(newurl, "^vine:")
        or string.match(newurl, "^android%-app:")
        or string.match(newurl, "^ios%-app:")
        or string.match(newurl, "^%${")) then
      check(urlparse.absolute(url, newurl))
    end
  end

  if allowed(url, nil) and status_code == 200
    and not string.match(url, "^https?://[^/]*img%.naver%.jp/") then
    html = read_file(file)
    if string.match(html, "go[pP]age%s*%([0-9]+%)") then
      local match = string.match(html, '<form%s+name="form"%s+action="[^"]+"%s+method="get">(.-)</form>')
      local params = ""
      if match then
        for key, value in string.gmatch(match, '<input%s+type="[^"]+"%s+name="([^"]+)"%s+value="([^"]*)"%s*/>') do
          params = params .. key .. "=" .. value .. "&"
        end
      end
      for page in string.gmatch(html, "goPage%(([0-9]+)%)") do
        if not string.find(params, "page=") then
          params = params .. "page=" .. page .. "&"
        else
          params = string.gsub(params, "page=[0-9]+", "page=" .. page)
        end
        params = string.match(params, "^(.-)&?$")
        checknewshorturl("?" .. params)
      end
    end
    if string.match(url, "/mymatome/") then
      check(string.gsub(url, "/mymatome/", "/profile/"))
    end
    for s in string.gmatch(html, "<dc:creator>%s*([^%s<]+)%s*</dc:creator>") do
      check(urlparse.absolute("https://matome.naver.jp/profile/", s))
    end
    if not done_tags then
      local match = string.match(html, '<ul%s+data%-pageData="([^"]+)"[^>]+>')
      if match then
        match = string.gsub(match, "&quot;", '"')
        local data = load_json_file(match)
        if not data["fetch"] or not data["totalPage"] or not data["userHash"]
          or not data["total"] then
          io.stdout:write("Could not extract some user data.\n")
          io.stdout:flush()
          abortgrab = true
        end
        for page=1,data["totalPage"] do
          post_data = '{' ..
            '"page":' .. tostring(page) ..
            ',"fetch":' .. data["fetch"] ..
            ',"userHash":"' .. data["userHash"] .. '"' ..
          '}'
          table.insert(urls, {
            url="https://matome.naver.jp/api/user/tag/list",
            post_data=post_data,
            headers={
              ["X-Requested-With"]="XMLHttpRequest",
              ["Accept"]="application/json, text/javascript, */*; q=0.01",
              ["Content-Type"]="application/json;charset=utf-8",
              ["Content-Length"]=tostring(string.len(post_data))
            }
          })
        end
        data = '{' ..
          '"page":1' ..
          ',"fetch":' .. data["total"] ..
          ',"userHash":"' .. data["userHash"] .. '"' ..
        '}'
        table.insert(urls, {
          url="https://matome.naver.jp/api/user/tag/list",
          post_data=post_data,
          headers={
            ["X-Requested-With"]="XMLHttpRequest",
            ["Accept"]="application/json, text/javascript, */*; q=0.01",
            ["Content-Type"]="application/json;charset=utf-8",
            ["Content-Length"]=tostring(string.len(post_data))
          }
        })
        done_tags = true
      end
    end
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
  end

  return urls
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]
  
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. "  \n")
  io.stdout:flush()

  if status_code >= 300 and status_code <= 399
    and not current_response_retry then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if downloaded[newloc] == true or addedtolist[newloc] == true
      or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end
  
  if status_code >= 200 and status_code <= 399 then
    downloaded[url["url"]] = true
  end

  if abortgrab == true then
    io.stdout:write("ABORTING...\n")
    io.stdout:flush()
    return wget.actions.ABORT
  end

  if status_code >= 500
    or (
      status_code >= 400
      and status_code ~= 404
    )
    or status_code == 0 then
    io.stdout:write("Server returned " .. http_stat.statcode .. " (" .. err .. "). Sleeping.\n")
    io.stdout:flush()
    local maxtries = 12
    if not allowed(url["url"], nil)
      or string.match(url["url"], "^https?://rr%.img%.naver%.jp/mig%?.*src=") then
      maxtries = 3
    end
    if tries >= maxtries then
      io.stdout:write("I give up...\n")
      io.stdout:flush()
      tries = 0
      if maxtries == 3 then
        return wget.actions.EXIT
      else
        return wget.actions.ABORT
      end
    else
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
      return wget.actions.CONTINUE
    end
  end

  tries = 0

  local sleep_time = 0

  if sleep_time > 0.001 then
    os.execute("sleep " .. sleep_time)
  end

  return wget.actions.NOTHING
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab == true then
    return wget.exits.IO_FAIL
  end
  return exit_status
end

