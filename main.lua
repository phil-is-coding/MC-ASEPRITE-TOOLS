-- MC Aseprite Tools — tools for making Minecraft textures in Aseprite.
-- Currently the skin viewer: a live 3D preview of the sprite you are painting,
-- rendered inside Aseprite. No browser, no temp files, no self-modifying code.

local VIEW_GROUP <const> = "view_controls"
local ISSUES_URL <const> = "https://github.com/phil-is-coding/MC-ASEPRITE-TOOLS/issues/new/choose"

-- Held at file level so exit() can reach the viewer that init() loaded.
local viewer, templates

function init(plugin)
  -- Aseprite hands every script run a fresh package.path, so a `require` from
  -- a menu callback fires long after ours has been discarded and cannot find
  -- the extension directory. Resolve the modules HERE, while the path is still
  -- ours, and hold them for the lifetime of the plugin.
  package.path = plugin.path .. "/?.lua;" .. package.path

  -- `require` caches every module for the whole Aseprite session, so a
  -- reinstall or update would otherwise keep running the previous copy until
  -- the next restart. Drop ours so they load fresh. Inside a plugin, Aseprite
  -- caches a module under "<plugin name>/<module>", so clear by that prefix as
  -- well as by the bare name.
  do
    local prefix = tostring(plugin.name) .. "/"
    local stale = {}
    for key in pairs(package.loaded) do
      if type(key) == "string" and (key:sub(1, #prefix) == prefix or key:sub(1, 4) == "src.") then
        stale[#stale + 1] = key
      end
    end
    for _, key in ipairs(stale) do package.loaded[key] = nil end
  end

  local function load(name)
    local ok, result = pcall(require, "src." .. name)
    if ok then return result, nil end
    -- Belt and braces: an absolute path needs no package.path at all.
    local ok2, result2 = pcall(dofile, app.fs.joinPath(plugin.path, "src", name .. ".lua"))
    if ok2 then return result2, nil end
    return nil, tostring(result)
  end

  local viewerError, templatesError
  viewer, viewerError = load("viewer")
  templates, templatesError = load("templates")

  -- Downloaded skins are remembered in the extension's preferences.
  local skinfetch = load("skinfetch")
  if skinfetch then pcall(function() skinfetch.setStore(plugin.preferences) end) end

  local function fail(what, err)
    app.alert{ title = "Minecraft Skin Viewer",
               text = { what .. " failed to load when Aseprite started:",
                        err or "unknown error",
                        "Try disabling and re-enabling the extension." } }
  end

  plugin:newMenuSeparator{ group = VIEW_GROUP }
  plugin:newMenuGroup{
    id = "msv",
    title = "MC Aseprite Tools",
    group = VIEW_GROUP,
  }

  plugin:newCommand{
    id = "msv_open",
    title = "View Skin",
    group = "msv",
    onenabled = function() return app.sprite ~= nil end,
    onclick = function()
      if not viewer then return fail("The viewer", viewerError) end
      -- Refuse up front rather than opening a viewer with nothing to show.
      local sizeErr = viewer.sizeError(app.sprite.width, app.sprite.height)
      if sizeErr then
        return app.alert{ title = "Minecraft Skin Viewer", text = sizeErr }
      end
      local ran, err = pcall(function() viewer.show(plugin) end)
      if not ran then
        app.alert{ title = "Minecraft Skin Viewer",
                   text = { "Could not open the viewer:", tostring(err) } }
      end
    end,
  }

  plugin:newCommand{
    id = "msv_new",
    title = "New Skin...",
    group = "msv",
    onclick = function()
      if not templates then return fail("The templates", templatesError) end
      local ran, err = pcall(function()
        local created = templates.chooser()
        -- Opening the viewer on a brand new skin is almost always what is
        -- wanted next, so do it rather than making them ask twice.
        if created and viewer then viewer.show(plugin) end
      end)
      if not ran then
        app.alert{ title = "Minecraft Skin Viewer",
                   text = { "Could not create the skin:", tostring(err) } }
      end
    end,
  }

  plugin:newCommand{
    id = "msv_report",
    title = "Report a Bug or Request a Feature...",
    group = "msv",
    onclick = function()
      -- Aseprite's own command for opening a web page, the one its Help menu
      -- uses, so no script permission is needed.
      local ok = pcall(function() app.command.Launch{ type = "url", path = ISSUES_URL } end)
      if not ok then
        app.alert{ title = "MC Aseprite Tools",
                   text = { "Could not open the browser. Issues are tracked at:", ISSUES_URL } }
      end
    end,
  }
end

function exit(plugin)
  -- Take the viewer down with the extension: otherwise its timer and sprite
  -- listeners keep running the old code after a disable or an update.
  if viewer then pcall(viewer.close) end
end
