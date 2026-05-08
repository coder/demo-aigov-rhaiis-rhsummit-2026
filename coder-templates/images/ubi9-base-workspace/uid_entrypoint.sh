#!/bin/bash
# OpenShift S2I-style UID entrypoint.
#
# Restricted-v2 SCC injects a random UID (e.g., 1000830042) into the
# pod's container. That UID has no /etc/passwd entry, so:
#   - Go's os/user.Current() fails with
#     "user: Current requires cgo or $USER set in environment"
#   - HOME defaults to "/" because nss-based home lookup misses
#   - sudo, ssh-keygen, npm, etc. silently misbehave
#
# Append a passwd entry for the runtime UID at startup so all of
# the above behave normally. Requires the image to have made
# /etc/passwd group-writable (mode g=u, group root) — see the Dockerfile.

set -e

USER_ID=$(id -u)

if ! getent passwd "${USER_ID}" >/dev/null 2>&1; then
  echo "coder:x:${USER_ID}:0:Coder user:/home/coder:/bin/bash" >> /etc/passwd 2>/dev/null || true
fi

export HOME=/home/coder
export USER=coder

# When invoked with no args (e.g., `kubectl exec -it`), drop into
# bash; otherwise exec the requested command. Coder workspace pods
# pass `["sh","-c", coder_agent.main.init_script]`, so the exec
# path is the normal one.
if [ "$#" -eq 0 ]; then
  exec /bin/bash
fi
exec "$@"
