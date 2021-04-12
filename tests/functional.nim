#
# Nim etcd client
#
# Copyright 2016 Federico Ceratto <federico.ceratto@gmail.com>
# Released under LGPLv3 License, see LICENSE file
#
# Functional tests
#
# WARNING: don't use it against a production datastore!
#
# NOTE: the tests are not isolated and meant to be run in sequence

import unittest
import json,
  times
from os import sleep, existsEnv
from sequtils import anyIt

import ../etcd_client

const
  test_dir = "/nim_etcd_test_dir"
  test_key = test_dir & "/test_key"
  root_password = "nim_etcd_root_pwd"

if not existsEnv("NIM_ENABLE_ETCD_FUNCTEST"):
  echo "WARNING: don't use this test against a production datastore!"
  echo "Set NIM_ENABLE_ETCD_FUNCTEST to enable it"
  quit(1)


suite "functional tests":

  let c = new_etcd_client(failover=false)

  test "basic":
    assert "a" / "b" == "a/b"
    assert "a/" / "b" == "a/b"
    assert "a/" / "/b" == "a/b"
    assert "a" / "/b" == "a/b"
    assert "" / "b" == "b"
    assert "" / "/b" == "/b"

  test "get_version":
    let v = c.get_version()
    assert v.hasKey("etcdserver")
    assert v.hasKey("etcdcluster")

  test "get_health":
    let v = c.get_health()
    assert v["health"].str == "true"

  test "get_debug_vars":
    let v = c.get_debug_vars()
    assert v.hasKey("cmdline")

  test "initial cleanup":
    try:
      c.rmdir(test_dir, recursive=true)
      discard c.ls(test_dir)
    except: discard

  test "ls":
    let d = c.ls("/")
    if d.hasKey("nodes"):
      for item in d["nodes"]:
        assert item["key"].str != test_dir, "This should have been deleted: " & $item

  test "mkdir":
    c.mkdir(test_dir)

  test "create, get":
    c.create(test_key, "Hello world")
    let r = c.get(test_key)
    assert r["value"].str == "Hello world", $r
    expect Exception:
      c.create(test_key, "Hello world")

  test "update, get":
    c.update(test_key, "Hello 2")
    let r = c.get(test_key)
    assert r["value"].str == "Hello 2", $r

  # Stats

  test "get_leader_stats":
    let s = c.get_leader_stats()
    assert s.hasKey("leader")
    assert s.hasKey("followers")

  test "get_self_stats":
    let s = c.get_self_stats()
    assert s.hasKey("name")
    assert s.hasKey("state")

  test "get_store_stats":
    let s = c.get_store_stats()
    assert s["expireCount"].getInt >= 0
    assert s["compareAndSwapFail"].getInt >= 0


  test "cluster members - simple test":
    let m1 = c.get_cluster_members()
    assert m1.len > 0
    expect Exception:
      c.add_cluster_member("http://localhost:2380")
    expect Exception:
      echo c.delete_cluster_member_by_id("bogus")
    expect Exception:
      echo c.delete_cluster_member_by_peer_url("http://bogus_bogus_bogus:2380")
    #c.add_cluster_member("http://localhost:4321")
    #let m2 = c.get_cluster_members()
    #assert m2.len == m1.len + 1
    #c.delete_cluster_member_by_peer_url("http://localhost:4321")

  test "set, get":
    c.set(test_key, "Foo")
    let r = c.get(test_key)
    ##assert r["value"].str == "Foo", $r

  test "refresh ttl":
    c.set(test_key, "Foo", ttl=1)
    let t0 = epochTime()
    sleep 800
    c.refresh(test_key, ttl=1)
    for tries in 0..20:
      sleep 100
      try:
        discard c.get(test_key)
      except:
        # the key timed out
        break

    expect Exception:
        discard c.get(test_key)

    let elapsed = epochTime() - t0
    echo elapsed
    assert elapsed > 1.8

  test "set, get with low TTL":
    c.set(test_key, "Foo", ttl=1)
    let t0 = epochTime()
    for tries in 0..20:
      sleep 100
      try:
        discard c.get(test_key)
      except:
        # the key timed out
        break

    expect Exception:
        discard c.get(test_key)

    let elapsed = epochTime() - t0
    assert elapsed > 1.0

  test "delete":
    c.create(test_key, "new")
    c.del(test_key)
    expect Exception:
      let r = c.get(test_key)
    expect Exception:
      c.update(test_key, "Hello world")

  test "mkdir, rmdir, nested keys":
    c.mkdir(test_dir / "a" / "b")
    expect Exception:
      c.rmdir(test_dir)

    checkpoint "create nested dirs"
    c.set(test_dir / "a/b/newdir1/newdir2/newdir3/newkey", "Foo")
    c.del(test_dir / "a/b/newdir1/newdir2/newdir3/newkey")
    c.rmdir(test_dir / "a/b/newdir1/newdir2/newdir3")
    c.rmdir(test_dir / "a/b/newdir1/newdir2")
    c.rmdir(test_dir / "a/b/newdir1")

    checkpoint "create key"
    c.set(test_dir / "a" / "b" / "key", "Foo")
    expect Exception:
      checkpoint "try to delete non-empty key"
      c.rmdir(test_dir / "a" / "b")
    checkpoint "delete key"
    c.del(test_dir / "a" / "b" / "key")

    checkpoint "delete dirs recursively"
    c.rmdir(test_dir / "a" / "b")
    c.rmdir(test_dir / "a")
#    c.rmdir(test_dir / "a", recursive=true)

  test "authentication: create/delete root user, enable/disable auth":
    assert generate_basicauth_header("root", root_password) == "Basic cm9vdDpuaW1fZXRjZF9yb290X3B3ZA=="
    assert c.is_auth_enabled() == false, "Auth should be disabled"
    var users = c.get_user_list()
    if users.kind != JNull:
      for user in users:
        assert user["user"].str != "root", "User 'root' should not exist"
    expect Exception:
      c.get_user_details("root")

    checkpoint "create root user"
    assert c.create_user("root", root_password)["user"].str == "root"
    let details = c.get_user_details("root")
    assert details["user"].str == "root"
    assert details.hasKey("roles")

    checkpoint "roles"
    let roles = c.get_role_list()
    assert anyIt(roles, it["role"].str == "root"), "root role should exist"
    let expected_perms = %* {"kv":{"read":["/*"],"write":["/*"]}}
    assert c.get_role_details("root")["permissions"] == expected_perms
    checkpoint "create, delete role"
    c.create_role("nim_test_role", expected_perms)
    assert c.get_role_details("nim_test_role")["permissions"] == expected_perms
    c.delete_role("nim_test_role")

    checkpoint "enable auth"
    c.enable_auth()

    var ac = new_etcd_client(username="root", password=root_password, failover=false)
    assert ac.is_auth_enabled() == true, "Auth should be enabled"
    ac = new_etcd_client(username="root", password=root_password, failover=false)
    checkpoint "disable auth"
    ac.disable_auth()
    checkpoint "delete root user"
    ac.delete_user("root")

    assert c.is_auth_enabled() == false, "Auth should be disabled"
    expect Exception:
      c.get_user_details("root")

  test "rmdir":
    c.rmdir(test_dir)

  test "final rmdir":
    try: c.rmdir(test_dir, recursive=true)
    except: discard


echo "Done"
