# Throwaway PATH stubs, so a test can exercise a script that shells out to
# docker/mysql/nc without a running stack. Source, don't execute.
#
# Sourced rather than run because stub_cmd and stub_cleanup mutate PATH in the
# CALLER's shell -- see the note on stub_cmd for why it is stub_cmd that does
# the prepending and not stub_dir.

# Makes the temp directory and prints it. Deliberately does NOT touch PATH:
# every caller captures this as d="$(stub_dir)", which is a command
# substitution, i.e. a subshell. Any `export PATH` here would die with that
# subshell and the stubs would never shadow anything -- which is exactly the
# silent failure this comment exists to prevent someone re-introducing.
stub_dir() {
  local d
  d="$(mktemp -d)"
  printf '%s\n' "$d"
}

# Writes an executable stub and puts its directory at the front of PATH.
#
# The PATH prepend lives here because stub_cmd is called directly in the
# caller's shell, so its export actually survives. Idempotent: calling it
# repeatedly for the same dir does not stack duplicate entries.
#
# The body is a bash script fragment; "$@" inside it receives the stub's own
# arguments, so a stub can branch on how it was called.
stub_cmd() { # <dir> <name> <body>
  local dir="$1" name="$2" body="$3"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$body"
  } > "$dir/$name"
  chmod +x "$dir/$name"
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH"; export PATH ;;
  esac
}

# Removes the stub dir and takes it back out of PATH. Dropping it from PATH
# matters: a test file that stubs twice would otherwise leave a deleted
# directory sitting in front of the second set of stubs.
stub_cleanup() { # <dir>
  local dir="${1:-}" out="" p
  [ -n "$dir" ] || return 0
  local IFS=:
  for p in $PATH; do
    [ "$p" = "$dir" ] && continue
    out="${out:+$out:}$p"
  done
  PATH="$out"
  export PATH
  [ -d "$dir" ] && rm -rf "$dir"
  return 0
}
