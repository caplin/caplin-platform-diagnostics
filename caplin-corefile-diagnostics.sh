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
  $(basename $0)  [binary]  core
  $(basename $0)  core  [binary]

    binary:  path to the binary that crashed
             (Required if the binary is not in the location
             recorded in the core file)

    core:    path to the core file dumped by the binary

DEPENDENCIES
  - CentOS/RHEL 6 or 7
  - GNU Debugger ('gdb' RPM package)

DESCRIPTION
  Collates diagnostic information for a core file dumped by a
  crashed Caplin process.

  This script collates the following diagnostics:
    - Operating system name and version
    - User limits
    - 'df' output for the binary's 'var' directory
    - The binary
    - The core file
    - If the binary is in a Caplin Deployment Framework:
      - 'dfw versions' output
    - If the GNU Debugger (GDB) is installed:
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
if [ $SHOW_HELP -eq 1 ]; then
  printf '%s\n\n' "$HELP"
  exit 0
fi
if [ ! -w . ]; then
  echo "This script must be run from a writeable directory. Aborting."
  exit 1
fi
# if ! command -v gdb >/dev/null 2>&1; then
#   echo "This script requires the GNU Debugger ('gdb' package). Aborting."
#   exit 1
# fi

if [ $# -eq 1 ]; then
  # One argument (core file)
  # Try to derive the location of the binary from the core file
  if [ ! -f $1 ]; then
    echo "File does not exist or is not a regular file: $1"
    exit 1
  fi
  if file -b $1 | cut -d, -f1 | grep 'core file' > /dev/null; then
    CORE=$(readlink -e $1)
    EXECFN=$(file --brief $1 | grep -o -E "execfn: '[^']+" | sed -r "s/execfn: '//")
    if [ -n "$EXECFN" ]; then
      if [ -f $EXECFN ]; then
        BINARY=$(readlink -e $EXECFN)
      else
        echo "Core file $(basename $1) has recorded the location of the crashed binary"
        echo "Cannot find binary $EXECFN"
        echo "Usage: $(basename $0) [binary] core"
        echo "       $(basename $0) core [binary]"
        exit 1
      fi
    else
      echo "Core file $(basename $1) has not recorded the location of the crashed binary"
      echo "Please specify both the binary and the core on the command line"
      echo "Usage: $(basename $0) [binary] core"
      echo "       $(basename $0) core [binary]"
      exit 1
    fi
  else
    echo "Not a core file: $1"
    echo "Usage: $(basename $0) [binary] core"
    echo "       $(basename $0) core [binary]"
    exit 1
  fi
elif [ $# -eq 2 ]; then
  # Two arguments
  # Determine which is the binary and which is the core file
  for f in $1 $2; do
    if [ ! -f $f ]; then
      echo "File does not exist or is not a regular file: $f"
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
  # Number of positional arguments > 2
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

###
# Write to STDOUT and diagnostics.log
# Param 1: log message
#
log () {
  echo "$1" | tee -a diagnostics.log
}

BINARY_FILENAME=$(basename $BINARY)
CORE_FILENAME=$(basename $CORE)
BINARY_DIR=$(dirname $BINARY)
HOSTNAME=$(hostname -s)
DFW=$(searchparents $BINARY_DIR dfw)
if [ -n $DFW ]; then
  DFW=$(readlink -e $DFW)
  DFW_ROOT=$(dirname $DFW)
fi
ARCHIVE=diagnostics-${HOSTNAME}-${BINARY_FILENAME}-${CORE_FILENAME//:/}-$(date +%Y%m%d%H%M%S)
if command -v gdb >/dev/null 2>&1; then
  GDB_INSTALLED=1
else
  GDB_INSTALLED=0
fi

# Infer the working directory of the binary.
# The inference is only accurate if the binary has not been
# moved from the original location in which it crashed.
if [ $BINARY_FILENAME == 'rttpd' -a -n $DFW_ROOT ]; then
  BINARY_WORKING_DIR=$DFW_ROOT/servers/Liberator
elif [ $BINARY_FILENAME == 'rttpd' -a -z $DFW_ROOT ]; then
  BINARY_WORKING_DIR=$(readlink -e $BINARY_DIR/..)
elif [ $BINARY_FILENAME == 'transformer' -a -n $DFW_ROOT ]; then
  BINARY_WORKING_DIR=$DFW_ROOT/servers/Transformer
elif [ $BINARY_FILENAME == 'transformer' -a -z $DFW_ROOT ]; then
  BINARY_WORKING_DIR=$(readlink -e $BINARY_DIR/..)
elif readlink -e $BINARY_DIR/.. | grep 'DataSource' > /dev/null ; then
  BINARY_WORKING_DIR=$(readlink -e $BINARY_DIR/..)
else
  BINARY_WORKING_DIR=$BINARY_DIR
fi

if [ $GDB_INSTALLED -eq 0 ]; then
  echo
  echo "The GNU Debugger (GDB) is not installed."
  echo
  echo "This script uses GDB to collate shared libraries referenced"
  echo "in the core file. Caplin Support require these libraries"
  echo "to analyse the core file."
  echo
  echo "We recommend that you exit the script and install the 'gdb' package."
  echo
  echo "If you can't install the 'gdb' package, continue running the script"
  echo "and submit the diagnostics to Caplin Support. After you submit the"
  echo "diagnostics, Caplin Support will contact you with details of how"
  echo "to collect the required libraries manually."
  echo
  read -p "Continue without installing GDB? [Y/N]: " RESPONSE
  if [ $RESPONSE != 'y' -a $RESPONSE != 'Y' ]; then
    echo
    exit 1
  fi
  echo
fi


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
log "Host:            $(hostname)"
log "Core:            ${CORE}"
log "Binary:          ${BINARY}"
log "GDB installed:   ${GDB_INSTALLED}"
log "Script temp dir: ./$(basename ${TEMP_DIR})"
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

log "Recording /proc/sys/kernel/core_pattern"
log "Recording /proc/sys/kernel/core_uses_pid"
for f in /proc/sys/kernel/core_pattern /proc/sys/kernel/core_uses_pid; do
  cat $f > $(echo $f | cut -c 2- | tr / -)
done

if [ -r /etc/security/limits.conf ]; then
  log "Recording /etc/security/limits.conf"
  cat /etc/security/limits.conf >> limits.conf
  if [ -d /etc/security/limits.d ]; then
    for f in /etc/security/limits.d/*; do
      log "Recording $f"
      cat $f >> limits.conf
    done
  fi
fi

log "Recording ulimit for current user"
ulimit -aS > ulimit-soft-$USER.out
ulimit -aH > ulimit-hard-$USER.out

if [ -d $BINARY_WORKING_DIR/var ]; then
  log "Recording 'df' output for $BINARY_WORKING_DIR/var"
  df -h $BINARY_WORKING_DIR/var > df.out
else
  log "Recording 'df' output for $BINARY_WORKING_DIR"
  df -h $BINARY_WORKING_DIR > df.out
fi

if [ -n "$DFW" ]; then
  log "Recording 'dfw versions' output"
  $DFW versions > dfw-versions.out 2>&1
else
  log "Skipping Deployment Framework output (no Deployment Framework found)"
fi

if [ $GDB_INSTALLED -eq 1 ]; then
  log "Getting thread backtraces from ${CORE_FILENAME}"
  gdb $BINARY -c $CORE --quiet \
    -ex "set confirm off" \
    -ex "set logging file ${CORE_FILENAME//:/}.backtrace.out" \
    -ex "set logging on" \
    -ex "set pagination off" \
    -ex "thread apply all bt full" \
    -ex "quit" > /dev/null 2>> diagnostics.log
else
  log "Skipping core-file thread backtraces (GDB not installed)"
fi

if [ $GDB_INSTALLED -eq 1 ]; then
  log "Collating libraries referenced by ${CORE_FILENAME}"
  gdb $BINARY -c $CORE --quiet \
    -ex "set confirm off" \
    -ex "set logging file libs-list.out" \
    -ex "set logging on" \
    -ex "set pagination off" \
    -ex "info sharedlibrary" \
    -ex "quit" > /dev/null 2>> diagnostics.log
  grep "^0x" ./libs-list.out | awk '{if ($5 != "")print $5}' &> libs-list.txt
  cat libs-list.txt | sed "s/\/\.\.\//\//g" | xargs tar -chvf ${CORE_FILENAME//:/}.libs.tar --ignore-failed-read &> /dev/null
else
  log "Skipping core-file shared libraries (GDB not installed)"
fi

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
