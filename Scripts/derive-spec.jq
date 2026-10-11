# Derives the spec the Swift generator consumes from the backend's own.
#
# pydantic v2 writes every `X | None` field as `anyOf: [X, {type: null}]`, and
# swift-openapi-generator does not support `{type: null}` — it logs
# "Schema "null" is not supported ... skipping" and silently omits the whole
# property. The first generated client therefore had no ServiceBlock.data,
# no poster URLs and no queue tracked_state. This rewrites each such schema
# to X alone and drops the property from `required`: a Swift Optional decoded
# with decodeIfPresent treats JSON null and absence identically, so the client
# sees exactly the values the backend sends.

def nullable: type == "object" and has("anyOf") and (.anyOf | any(.type == "null"));

# 1. Properties that may be null become optional, before the marker is removed.
def relax_required:
  if type == "object" and has("properties") then
    .required = [(.required // [])[] as $k | select(.properties[$k] | nullable | not) | $k]
    | if .required == [] then del(.required) else . end
  else . end;

# 2. Strip the null branch; a lone survivor replaces the anyOf, keeping siblings
#    such as title, description and default.
def strip_null:
  if nullable then
    (.anyOf |= map(select(.type != "null")))
    | if (.anyOf | length) == 1 then (.anyOf[0] + del(.anyOf)) else . end
  else . end;

# 3. The names of services and arrs in answers are open: a server that knows
#    a service this build does not (Lidarr was the first) sends a value
#    outside the enum, and a generated Swift enum fails the whole list over
#    it — every queue item, every status row. So each schema property called
#    `app` or `service` loses its enum and stays a plain string; ArrdeckData
#    reads it into ArrApp or Services.known and drops the rows it cannot name.
#    No request body (`*In`) carries such an enum, so only answers change, and
#    path parameters such as `{app}` were never enums.
def open_names:
  if type == "object" and has("properties") then
    .properties |= with_entries(
      if (.key == "app" or .key == "service") and (.value | type == "object" and has("enum"))
      then .value |= del(.enum) else . end)
  else . end;

# 4. A search result's kind is open the same way: the server added artist and
#    album with Lidarr, and a kind this build has never heard of would fail the
#    whole result list rather than the one row. Only SearchResultOut: the other
#    `kind` enums in the answers (cleanup, subtitles, activity) feed typed
#    choices of their own. ArrdeckData reads it into SearchKind and drops rows
#    it cannot name.
def open_search_kind:
  .SearchResultOut.properties.kind |= del(.enum);

walk(relax_required) | walk(strip_null) | .components.schemas |= (map_values(open_names) | open_search_kind)
