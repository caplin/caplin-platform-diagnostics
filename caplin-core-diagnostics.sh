#!/bin/bash

###
# MIT License
#
# Copyright (c) 2019 Caplin Systems Limited
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

HELP="$(cat << EOF

NAME
  $(basename $0) - run diagnostics on a core file

SYNOPSIS
  $(basename $0) binary core

    binary:        path to the binary that crashed
    core:          path to the core file dumped by the binary

DEPENDENCIES
  - CentOS/RHEL 6 or 7
  - GNU Debugger ('gdb' RPM package)

DESCRIPTION
  Collates diagnostic information for a core file dumped by a
  crashed Caplin process.

  This script collates the following diagnostics:
    - Operating system name and version
    - If the binary is in a Caplin Deployment Framework:
      - 'dfw versions' output
    - The binary
    - The core file
    - Thread backtrace from the core file
    - Shared libraries referenced in the core file

EOF
)"

if [ $# -ne 2 ]; then
  printf '%s\n\n' "$HELP"
  exit 1
fi
if [ $1 == 'help' -o $1 == '-h' -o $1 == '--help' ]; then
  printf '%s\n\n' "$HELP"
  exit 0
fi
for f in $1 $2; do
  if [ ! -f $f ]; then
    echo "File $f does not exist or is not a regular file"
    exit 1
  fi
done
if command -v file >/dev/null 2>&1; then
  if ! file -b $1 | cut -d, -f1 | grep 'executable' > /dev/null; then
    echo "File '$1' is not an executable"
    exit 1
  fi
  if ! file -b $2 | cut -d, -f1 | grep 'core file' > /dev/null; then
    echo "File '$2' is not a core file"
    exit 1
  fi
fi
if [ ! -w . ]; then
  echo "This script must be run from a writeable directory. Aborting."
  exit 1
fi
if ! command -v gdb >/dev/null 2>&1; then
  echo "This script requires the GNU Debugger ('gdb' package). Aborting."
  exit 1
fi


##
# Search for a file in parent directories
# Param 1: starting directory
# Param 2: file to search for
#
searchparents () {
  slashes=${1//[^\/]/}
  directory="$1"
  for (( n=${#slashes}; n>0; --n ))
  do
    test -e "$directory/$2" && readlink -e "$directory/$2" && return
    directory="$directory/.."
  done
}

log () {
  echo "$1" | tee -a diagnostics.log
}

BINARY=$(readlink -e $1)
CORE=$(readlink -e $2)
BINARY_FILENAME=$(basename $BINARY)
CORE_FILENAME=$(basename $CORE)
BINARY_DIR=$(dirname $BINARY)
HOSTNAME=$(hostname -s)
DFW=$(searchparents $BINARY_DIR dfw)
if [ ! -z $DFW ]; then
  DFW=$(readlink -e $DFW)
fi
ARCHIVE=diagnostics-${HOSTNAME}-${BINARY_FILENAME}-${CORE_FILENAME}-$(date +%Y%m%d%H%M%S)

if ! mkdir -p $ARCHIVE; then
  echo "Could not create directory $ARCHIVE"
  exit 1
fi
TEMP_DIR=$(readlink -e $ARCHIVE)
cd $TEMP_DIR
ln -s $BINARY
ln -s $CORE

log
log "Caplin Core-file Diagnostics"
log "============================"
log
log "Script temp dir: $(basename ${TEMP_DIR})"
log

if [ -r /etc/os-release ]; then
  log "Recording /etc/os-release"
  cp /etc/os-release os-release
fi
if [ -r /etc/redhat-release ]; then
  log "Recording /etc/redhat-release"
  cp /etc/redhat-release redhat-release
fi
log "Recording 'uname -a' output"
uname -a > uname.out

if [ -x "$DFW" ]; then
  log "Recording 'dfw versions' output"
  $DFW versions > dfw-versions.out 2>&1
else
  log "Skipping Deployment Framework output (no Deployment Framework found)"
fi

log "Getting thread backtraces from ${CORE_FILENAME}"
gdb $BINARY -c $CORE --quiet \
  -ex "set confirm off" \
  -ex "set logging file ${CORE_FILENAME}.backtrace.out" \
  -ex "set logging on" \
  -ex "set pagination off" \
  -ex "thread apply all bt full" \
  -ex "quit" > /dev/null 2>> diagnostics.log

log "Collating libraries referenced by ${CORE_FILENAME} (using GDB)"
gdb $BINARY -c $CORE --quiet \
  -ex "set confirm off" \
  -ex "set logging file libs-list.out" \
  -ex "set logging on" \
  -ex "set pagination off" \
  -ex "info sharedlibrary" \
  -ex "quit" > /dev/null 2>> diagnostics.log
grep "^0x" ./libs-list.out | awk '{if ($5 != "")print $5}' &> libs-list.txt
cat libs-list.txt | sed "s/\/\.\.\//\//g" | xargs tar -chvf ${CORE_FILENAME}.libs.tar &> /dev/null

log
log "DONE"
log
log "Files collected:"
log
for f in *; do
  log "  $f"
done
log
log "Archiving files to ${ARCHIVE}.tar.gz"
cd ..
tar -chzf ${ARCHIVE}.tar.gz $(basename ${TEMP_DIR})/*
rm $TEMP_DIR/*
rmdir $TEMP_DIR
echo
echo "Please login to https://www.caplin.com/account/uploads"
echo "and upload the archive to Caplin Support."
echo
