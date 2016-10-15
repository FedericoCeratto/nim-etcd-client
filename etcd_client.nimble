# Package

version       = "0.1.0"
author        = "Federico Ceratto"
description   = "etcd client library"
license       = "LGPLv3"

# Dependencies

requires "nim >= 0.15.0"

task functional_tests, "Run functional tests":
  exec "NIMTEST_NO_COLOR=1 nim c -p=.  -r tests/functional.nim"
