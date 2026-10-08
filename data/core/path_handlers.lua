-- Handlers for paths that are not on the local file system (for example
-- files on another machine, see the thither plugin). Core only consults them;
-- without a registered handler every path is local.
--
-- A handler is a table:
--   claims(path) -> bool             required: the handler owns this path
--   load(doc, filename) -> handled   optional: load the document itself
--   loaded(doc, filename)            optional: called after core loaded it
--   save(doc, abs_filename)          optional: save the document itself
--   release(doc)                     optional: drop per-document state
--   async_save = true                save in a thread (slow storage)
--
-- A document loaded or saved through a handler keeps it in doc.path_handler.
-- A save may raise a table error with a `handle(doc, retry)` function, which
-- doc:save calls instead of showing the generic "save failed" message.
local path_handlers = { list = {} }

function path_handlers.register(handler)
  assert(type(handler) == "table" and type(handler.claims) == "function",
    "path handler needs a claims(path) function")
  table.insert(path_handlers.list, handler)
  return handler
end

function path_handlers.unregister(handler)
  for i, h in ipairs(path_handlers.list) do
    if h == handler then table.remove(path_handlers.list, i) return true end
  end
  return false
end

---Returns the handler that claims `path`, or nil for a local path.
function path_handlers.find(path)
  if type(path) ~= "string" then return nil end
  for _, h in ipairs(path_handlers.list) do
    if h.claims(path) then return h end
  end
  return nil
end

function path_handlers.is_virtual(path)
  return path_handlers.find(path) ~= nil
end

return path_handlers
