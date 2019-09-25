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
  $(basename $0)  binary  core

    binary:   path to the binary that crashed
    core:     path to the core file dumped by the binary

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

SHOW_HELP=0
POSITIONAL=()
while [[ $# -gt 0 ]]
do
  key="$1"
  case $key in
      -h|--help)
      SHOW_HELP=1
      shift
      ;;
      *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [ $# -eq 0 ]; then
  printf '%s\n\n' "$HELP"
  exit 1
fi
if [ $1 == 'help' -o $1 == '-h' -o $1 == '--help' ]; then
  printf '%s\n\n' "$HELP"
  exit 0
fi
if [ ! -w . ]; then
  echo "This script must be run from a writeable directory. Aborting."
  exit 1
fi
if ! command -v gdb >/dev/null 2>&1; then
  echo "This script requires the GNU Debugger ('gdb' package). Aborting."
  exit 1
fi

if [ $# -eq 1 ]; then
  if [ ! -f $1 ]; then
    echo "File $1 does not exist or is not a regular file"
    exit 1
  fi
  if file -b $1 | cut -d, -f1 | grep 'core file' > /dev/null; then
    CORE=$(readlink -e $1)
    # Read the core file type and extract the binary filename
    EXECFN=$(file --brief $1 | grep -o -E "execfn: '[^']+" | sed -r "s/execfn: '//")
    if [ ! -z "$EXECFN" ]; then
      if [ -f $EXECFN ]; then
        BINARY=$(readlink -e $EXECFN)
      else
        echo "Core file $1 contains the location of the crashed binary"
        echo "Cannot find binary $EXECFN"
        echo "Usage: $(basename $0) [binary] <core>"
        echo "       $(basename $0) <core> [binary]"
        exit 1
      fi
    else
      echo "Core file $1 has not recorded the location of the crashed binary"
      echo "Please specify both the binary and the core on the command line"
      echo "Usage: $(basename $0) [binary] <core>"
      echo "       $(basename $0) <core> [binary]"
      exit 1
    fi
  else
    echo "Argument $1 is not a core file"
    echo "Usage: $(basename $0) [binary] <core>"
    echo "       $(basename $0) <core> [binary]"
    exit 1
  fi
elif [ $# -eq 2 ]; then
  for f in $1 $2; do
    if [ ! -f $f ]; then
      echo "File $f does not exist or is not a regular file"
      exit 1
    fi
  done
  if file -b $1 | cut -d, -f1 | grep 'core file' > /dev/null; then
    CORE=$(readlink -e $1)
  elif file -b $1 | cut -d, -f1 | grep 'executable' > /dev/null; then
    BINARY=$(readlink -e $1)
  fi
  if file -b $2 | cut -d, -f1 | grep 'core file' > /dev/null; then
    CORE=$(readlink -e $2)
  elif file -b $2 | cut -d, -f1 | grep 'executable' > /dev/null; then
    BINARY=$(readlink -e $2)
  fi
  if [ -z $BINARY -o -z $CORE ]; then
    printf '%s\n\n' "$HELP"
    exit 1
  fi
else
  printf '%s\n\n' "$HELP"
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

BINARY_FILENAME=$(basename $BINARY)
CORE_FILENAME=$(basename $CORE)
BINARY_DIR=$(dirname $BINARY)
HOSTNAME=$(hostname -s)
DFW=$(searchparents $BINARY_DIR dfw)
if [ ! -z $DFW ]; then
  DFW=$(readlink -e $DFW)
  DFW_ROOT=$(dirname $DFW)
fi
ARCHIVE=diagnostics-${HOSTNAME}-${BINARY_FILENAME}-${CORE_FILENAME//:/}-$(date +%Y%m%d%H%M%S)

if ! mkdir -p $ARCHIVE; then
  echo "Could not create directory $ARCHIVE"
  exit 1
fi
TEMP_DIR=$(readlink -e $ARCHIVE)
cd $TEMP_DIR
ln -s $BINARY
ln -s $CORE ${CORE_FILENAME//:/}

log
log "Caplin Core-file Diagnostics"
log "============================"
log
log "Core:            ${CORE}"
log "Binary:          ${BINARY}"
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
  -ex "set logging file ${CORE_FILENAME//:/}.backtrace.out" \
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
cat libs-list.txt | sed "s/\/\.\.\//\//g" | xargs tar -chvf ${CORE_FILENAME//:/}.libs.tar &> /dev/null

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
