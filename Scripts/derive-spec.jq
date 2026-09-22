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

walk(relax_required) | walk(strip_null)
