#
# Nim etcd client
#
# Copyright 2016 Federico Ceratto <federico.ceratto@gmail.com>
# Released under LGPLv3 License, see LICENSE file
#

# TODO:
# implement/test ttl on dir
# implement reconnect
# implement Atomic Compare-and-Delete & similar
# implement Refreshing key TTL

import httpclient,
  logging,
  strutils,
  json,
  uri

from httpcore import HttpMethod
from base64 import encode

const api_version_prefix = "v2"

type EtcdClient* = ref object of RootObj
  hostname, username, password: string
  baseurl, apiurl, basic_auth_header: string
  port: int
  hc: HttpClient


proc `/`*(a, b: string): string =
  ## Join URL path components using a slash
  if a.len == 0:
    return b
  elif a[^1] == '/':
    if b[0] == '/':
      return a & b[1..^1]
    else:
      return a & b
  elif b[0] == '/':
    return a & b
  else:
    return a & "/" & b

proc generate_basicauth_header*(username, password: string): string =
  ## Generate HTTP Basic Auth header
  "Basic " & encode("$#:$#" % [username, password])

proc new_etcd_client*(hostname="127.0.0.1", port=2379, proto="http", srv_domain="",
    read_timeout=60, failover=true, cert="", ca_cert="", username="",
    password="", reconnect=true): EtcdClient =
  ## Create new Etcd client
  new result
  result.hc = newHttpClient()
  assert proto in ["http", "https"]
  result.baseurl = "$#://$#:$#" % [proto, hostname, $port]
  result.apiurl = result.baseurl / api_version_prefix

  if username.len > 0 and password.len > 0:
    if proto != "https":
      if hostname notin ["127.0.0.1", "::1", "localhost"]:
        echo "WARNING: Basic Auth used without SSL!"
      if failover:
        echo "WARNING: Basic Auth used without SSL while failover is enabled!"
    result.basic_auth_header = generate_basicauth_header(username, password)
  else:
    result.basic_auth_header = ""



# API interaction

type ContentType {.pure.} = enum form, json

proc call_api(self: EtcdClient, path: string, httpmethod: HttpMethod, ctype=ContentType.form, body="", from_key=""): JsonNode =
  self.hc.headers = newHttpHeaders()
  self.hc.headers["Content-Type"] = case ctype
    of ContentType.form: "application/x-www-form-urlencoded; charset=utf-8"
    of ContentType.json: "application/json"

  if self.basic_auth_header.len > 0:
    self.hc.headers["Authorization"] = self.basic_auth_header
  let r = self.hc.request(self.apiurl / path, httpmethod, body=body)
  if not r.status.startswith("2"):
    let errmsg =
      try: " - " & parseJson(r.body)["message"].str
      except: ""
    raise newException(Exception, r.status & errmsg)

  let j =
    if r.headers.hasKey("Content-Length") and r.headers["Content-Length"] == "0":
      newJNull()
    else:
      parseJson(r.body)

  return if from_key == "": j else: j[from_key]

proc call_api_form(self: EtcdClient, path: string, httpmethod: HttpMethod,
    params: MultipartEntries, from_key=""): JsonNode =
  ## Call API using form params
  var body = ""
  for p in params:
    if body.len != 0:
      body.add "&"
    body.add "$#=$#" % [p.name, p.content]
  return self.call_api(path, httpmethod, ctype=ContentType.form, body=body, from_key=from_key)

proc call_api_json(self: EtcdClient, path: string, httpmethod: HttpMethod, payload: JsonNode, from_key=""): JsonNode =
  ## Call API using JSON params
  let body = $payload
  return self.call_api(path, httpmethod, ctype=ContentType.json, body=body, from_key=from_key)


# Keys and dirs access

proc ls*(self: EtcdClient, key: string, recursive=false): JsonNode =
  ## List directory elements
  ## Caution: "nodes" is missing when a directory is empty
  ## Example: [{"key":"/example","dir":true,"modifiedIndex":142,"createdIndex":142}, ... ]
  return self.call_api("keys" / key, HttpGet, from_key="node")
  #TODO: test recursive

proc get*(self: EtcdClient, key: string): JsonNode =
  ## Get a key
  return self.call_api("keys" / key, HttpGet, from_key="node")

proc wait*(self: EtcdClient, key: string, waitIndex= -1): JsonNode =
  ## Wait for a key to change
  ## Unlike get(), returns both "node" and "prevNode"
  var path = "keys" / key & "?wait=true"
  if waitIndex != -1:
    path.add "&waitIndex=$#" % $waitIndex
  return self.call_api(path, HttpGet)

proc set*(self: EtcdClient, key, value: string, ttl= -1): JsonNode {.discardable.} =
  ## Set (create or update) a key
  if ttl == -1:
    return self.call_api_form("keys" / key, HttpPut, {"value": value}, from_key="node")
  else:
    return self.call_api_form("keys" / key, HttpPut, {"value": value, "ttl": $ttl}, from_key="node")

proc create*(self: EtcdClient, key, value: string): JsonNode {.discardable.} =
  ## Create a new key
  return self.call_api_form("keys" / key & "?prevExist=false", HttpPut, {"value": value}, from_key="node")

proc update*(self: EtcdClient, key, value: string): JsonNode {.discardable.} =
  ## Update an existing key
  return self.call_api_form("keys" / key & "?prevExist=true", HttpPut, {"value": value}, from_key="node")

proc del*(self: EtcdClient, key: string): JsonNode {.discardable.} =
  ## Delete a key
  return self.call_api("keys" / key, HttpDelete, from_key="node")

proc mkdir*(self: EtcdClient, path: string, ttl= -1): JsonNode {.discardable.} =
  ## Create a directory
  return self.call_api_form("keys" / path, HttpPut, {"dir": "true"}, from_key="node")

proc rmdir*(self: EtcdClient, path: string, recursive=false): JsonNode {.discardable.} =
  ## Delete a directory
  if recursive:
    return self.call_api("keys" / path & "?recursive=true", HttpDelete, from_key="node")
  else:
    return self.call_api("keys" / path & "?dir=true", HttpDelete, from_key="node")


# Status

proc get_version*(self: EtcdClient): JsonNode =
  ## Get etcd version
  let r = self.hc.request(self.baseurl / "version", HttpGet)
  if not r.status.startswith("2"):
    raise newException(Exception, r.status)
  return parseJson(r.body)

proc get_health*(self: EtcdClient): JsonNode =
  ## Get etcd health
  let r = self.hc.request(self.baseurl / "health", HttpGet)
  if not r.status.startswith("2"):
    raise newException(Exception, r.status)
  return parseJson(r.body)

proc get_leader_stats*(self: EtcdClient): JsonNode =
  ## Get leader stats
  ## E.g. {"leader":"ce2a822cea30bfca","followers":{}}
  return self.call_api("/stats/leader", HttpGet)

proc get_self_stats*(self: EtcdClient): JsonNode =
  ## Get self stats
  return self.call_api("/stats/self", HttpGet)

proc get_store_stats*(self: EtcdClient): JsonNode =
  ## Get store stats
  return self.call_api("/stats/store", HttpGet)


# Members

proc get_cluster_members*(self: EtcdClient): JsonNode =
  ## Get cluster members
  return self.call_api("/members", HttpGet, from_key="members")

proc add_cluster_member*(self: EtcdClient, address: string): JsonNode {.discardable.} =
  ## Add cluster member
  let body = %* {"peerURLs": [address]}
  return self.call_api_json("/members", HttpPost, body)

proc delete_cluster_member_by_id*(self: EtcdClient, id: string): JsonNode {.discardable.} =
  ## Delete cluster member by id
  return self.call_api("/members/$#" % id, HttpDelete)

proc delete_cluster_member_by_name*(self: EtcdClient, name: string): JsonNode {.discardable.} =
  ## Delete cluster member by name
  let members = self.get_cluster_members()
  for m in members:
    if m["name"].str == name:
      return self.delete_cluster_member_by_id(m["id"].str)
  raise newException(Exception, "Member $# not found" % name)

proc delete_cluster_member_by_peer_url*(self: EtcdClient, url: string): JsonNode {.discardable.} =
  ## Delete cluster member by peer URL
  let members = self.get_cluster_members()
  for m in members:
    for peer_url in m["peerURLs"]:
      if peer_url.str == url:
        return self.delete_cluster_member_by_id(m["id"].str)
  raise newException(Exception, "Member not found")


# Users

proc get_user_list*(self: EtcdClient): JsonNode =
  ## Get user list
  return self.call_api("/auth/users", HttpGet, from_key="users")

proc get_user_details*(self: EtcdClient, username: string): JsonNode {.discardable.} =
  ## Get user details
  return self.call_api("/auth/users/$#" % username, HttpGet)

proc create_user*(self: EtcdClient, username, password: string): JsonNode {.discardable.} =
  ## Create or update an user
  let body = %* {"user": username,"password": password}
  return self.call_api_json("/auth/users/$#" % username, HttpPut, body)

proc delete_user*(self: EtcdClient, username: string): JsonNode {.discardable.} =
  ## Delete user
  return self.call_api("/auth/users/$#" % username, HttpDelete)


# Roles

proc get_role_list*(self: EtcdClient): JsonNode =
  ## Get role list
  return self.call_api("/auth/roles", HttpGet, from_key="roles")

proc get_role_details*(self: EtcdClient, role: string): JsonNode {.discardable.} =
  ## Get role details
  return self.call_api("/auth/roles/$#" % role, HttpGet)

proc create_role*(self: EtcdClient, role: string, perms: JsonNode): JsonNode {.discardable.} =
  ## Create role
  ## Permissions example: {"kv":{"read":["/*"],"write":["/*"]}}
  let body = %* {"role": role, "permissions": perms}
  return self.call_api_json("/auth/roles/$#" % role, HttpPut, body)

proc delete_role*(self: EtcdClient, role: string): JsonNode {.discardable.} =
  ## Delete role
  return self.call_api("/auth/roles/$#" % role, HttpDelete)

# TODO grant roles to users


# Auth

proc is_auth_enabled*(self: EtcdClient): bool =
  ## Check if auth is enabled
  return self.call_api("/auth/enable", HttpGet)["enabled"].getBool

proc enable_auth*(self: EtcdClient): JsonNode {.discardable.} =
  ## Enable authentication
  try:
    return self.call_api("/auth/enable", HttpPut)
  except Exception:
    return %* {}

proc disable_auth*(self: EtcdClient): JsonNode {.discardable.} =
  ## Disable authentication
  return self.call_api("/auth/enable", HttpDelete)


# Misc

proc set_logging_level*(self: EtcdClient, level: string): JsonNode {.discardable.} =
  ## Set logging level
  doAssert level in ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]
  let body = %* {"Level":level}
  return self.call_api_json("/config/local/log", HttpPut, body)

proc get_debug_vars*(self: EtcdClient): JsonNode {.discardable.} =
  ## Get debugging variables
  let r = self.hc.request(self.baseurl / "debug/vars", HttpGet)
  if not r.status.startswith("2"):
    raise newException(Exception, r.status)
  return parseJson(r.body)

