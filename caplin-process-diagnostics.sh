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
  $(basename $0) - run diagnostics on a Caplin process

SYNOPSIS
  $(basename $0) [options] pid

    [options]:  see OPTIONS below
    pid:        process identifier

DEPENDENCIES
  - CentOS/RHEL 6 or 7
  - GNU Debugger ('gdb' RPM package)

DESCRIPTION
  Collates diagnostic information for a Caplin process, without
  terminating the process.

  This script captures the following diagnostics:
    - Operating system name and version
    - Process limits
    - 'top' output for the system (30 seconds)
    - 'top' output for the process (30 seconds)
    - 'df' output for the process's <working-dir>/var directory
    - 'free' output
    - 'vmstat' output (30 seconds)
    - If the process's binary is in a Caplin Deployment Framework:
      - 'dfw info' output
      - 'dfw status' output
      - 'dfw versions' output
    - If the process has a Java virtual machine (JVM):
      - 'jcmd <pid> Thread.print' output
      - 'jcmd <pid> GC.heap_info' output
      - 'jcmd <pid> VM.system_properties' output
      - 'jcmd <pid> VM.flags' output
      - 'jcmd <pid> PerfCounter.print' output
      - 'jstat -gc <pid>' output
      - 'jstat -gcutil <pid>' output
    - If the GNU Debugger is installed:
      - 3x thread backtraces (10 seconds apart)
      - Core dump
      - Thread backtrace for core dump
      - Copy of shared libraries referenced in the core dump

OPTIONS
  -h --help     Display this message

  --strace      Include the optional strace diagnostic.
                Enable only if requested by Caplin Support.

  --jvm-heap    Include the optional JVM heap dump diagnostic.
                Enable only if requested by Caplin Support.

  --jvm-class-histogram
                Include the optional JVM class histogram diagnostic.
                Enable only if requested by Caplin Support.

EOF
)"

RUN_STRACE=0
RUN_JVM_HEAP=0
RUN_JVM_CLASS_HISTOGRAM=0
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
      --strace)
      RUN_STRACE=1
      shift
      ;;
      --jvm-heap)
      RUN_JVM_HEAP=1
      shift
      ;;
      --jvm-class-histogram)
      RUN_JVM_CLASS_HISTOGRAM=1
      shift
      ;;
      *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [ $# -ne 1 ]; then
  printf '%s\n\n' "$HELP"
  exit 1
fi
if [ $SHOW_HELP -eq 1 ]; then
  printf '%s\n\n' "$HELP"
  exit 0
fi
if [ ! -e "/proc/$1" ]; then
  echo "Process $1 not found"
  exit 1
fi
if [ ! -w . ]; then
  echo "This script must be run from a writeable directory. Aborting."
  exit 1
fi

PID=$1
WHOAMI=$(whoami)
PROC_USER_ID=$(stat -c %u /proc/${PID})
PROC_USERNAME=$(stat -c %U /proc/${PID})
PROC_MEMORY=$(ps -o vsz= -q $PID)
PROC_MEMORY=$(( $PROC_MEMORY / 1024 ))
if [ $WHOAMI != 'root' -a $WHOAMI != $PROC_USERNAME ]; then
  echo "This script must be run as root (recommended) or the same user as process $PID ($PROC_USERNAME)"
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
    test -e "${directory}/${2}" && readlink -e "${directory}/${2}" && return
    directory="${directory}/.."
  done
}

###
# Write to STDOUT and diagnostics.log
# Param 1: log message
#
log () {
  echo "$1" | tee -a diagnostics.log
}

HOSTNAME=$(hostname -s)
DISK_SPACE=$(df -Pk . | awk 'NR==2 {print $4}')
DISK_SPACE=$(( $DISK_SPACE / 1024 ))
BINARY=$(readlink -e /proc/${PID}/exe)
BINARY_DIR=$(dirname $BINARY)
CMD=$(basename $BINARY)
WORKING_DIR=$(pwdx $PID | cut -d' ' -f2)
CORE=${CMD}.core.${PID}
DFW=$(searchparents $BINARY_DIR dfw)
if [ ! -z $DFW ]; then
  DFW=$(readlink -e $DFW)
fi
ARCHIVE=diagnostics-${HOSTNAME}-${CMD}-${PID}-$(date +%Y%m%d%H%M%S)
if [ $WHOAMI == 'root' ]; then
  # Use the process user's JAVA_HOME
  export JAVA_HOME=$(su -l -c 'echo $JAVA_HOME' $PROC_USERNAME)
fi
if command -v gdb >/dev/null 2>&1; then
  GDB_INSTALLED=1
else
  GDB_INSTALLED=0
fi
if [ -r /proc/sys/kernel/yama/ptrace_scope ]; then
  YAMA_PTRACE_SCOPE=$(cat /proc/sys/kernel/yama/ptrace_scope)
else
  YAMA_PTRACE_SCOPE=0
fi
if [ -r /sys/fs/selinux/booleans/deny_ptrace ]; then
  SELINUX_DENY_PTRACE=$(cat /sys/fs/selinux/booleans/deny_ptrace | cut -d' ' -f1)
else
  SELINUX_DENY_PTRACE=0
fi


# Warn the user when specific tests cannot run
declare -a WARNINGS
if [ $GDB_INSTALLED -eq 0 ]; then
  WARNINGS+=("GDB thread backtrace (requires 'gdb' package)" "GDB core dump (requires 'gdb' package)")
fi
if [ $SELINUX_DENY_PTRACE -eq 1 ]; then
  if [ $RUN_STRACE -eq 1 ]; then
    WARNINGS+=("strace (prohibited by SELINUX deny_ptrace)")
  fi
  WARNINGS+=("GDB thread backtrace (prohibited by SELINUX deny_ptrace)")
  WARNINGS+=("GDB core dump (prohibited by SELINUX deny_ptrace)")
fi
if ! command -v strace >/dev/null 2>&1; then
  if [ $RUN_STRACE -eq 1 ]; then
    WARNINGS+=("strace (requires 'strace' package)")
  fi
fi
if [ $YAMA_PTRACE_SCOPE -eq 3 ]; then
  WARNINGS+=("GDB thread backtrace (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)")
  WARNINGS+=("GDB core dump (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)")
  if [ $RUN_STRACE -eq 1 ]; then
    WARNINGS+=("strace (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)")
  fi
fi
if [ $YAMA_PTRACE_SCOPE -gt 0 -a $YAMA_PTRACE_SCOPE -lt 3 -a $WHOAMI != 'root' ]; then
  WARNINGS+=("GDB thread backtrace (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)")
  WARNINGS+=("GDB core dump (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)")
  if [ $RUN_STRACE -eq 1 ]; then
    WARNINGS+=("strace (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)")
  fi
fi
if [ $DISK_SPACE -lt $PROC_MEMORY ]; then
  WARNINGS+=("GDB core dump (insufficient free disk space -- need at least ${PROC_MEMORY}MB)")
fi
if ! command -v jcmd >/dev/null 2>&1; then
  WARNINGS+=("JVM diagnostics (jcmd command not found in executable path)")
fi
if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo
  echo "Script user:               ${WHOAMI}"
  echo "Process user:              ${PROC_USERNAME}"
  if [ -r /proc/sys/kernel/yama/ptrace_scope ]; then
    echo "kernel.yama.ptrace_scope:  ${YAMA_PTRACE_SCOPE}"
  fi
  if [ -r /sys/fs/selinux/booleans/deny_ptrace ]; then
    echo "SELINUX status:            $(getenforce)"
    echo "SELINUX deny_ptrace:       ${SELINUX_DENY_PTRACE}"
  fi
  echo
  echo "The following diagnostics will be skipped:"
  for warning in "${WARNINGS[@]}"; do
    echo "  - $warning"
  done
  echo
  read -p "Continue? [Y/N]: " RESPONSE
  if [ $RESPONSE != 'y' -a $RESPONSE != 'Y' ]; then
    echo
    exit 1
  fi
  echo
fi

if ! mkdir -p $ARCHIVE; then
  echo "Could not create temporary directory $ARCHIVE"
  exit 1
fi
TEMP_DIR=$(readlink -e $ARCHIVE)
TEMP_DIR_USER=$(stat . -c %U)
TEMP_DIR_GROUP=$(stat . -c %G)
if [ $WHOAMI == 'root' ]; then
  chown $TEMP_DIR_USER:$TEMP_DIR_GROUP $TEMP_DIR
fi
cd $TEMP_DIR

log
log "Caplin Process Diagnostics"
log "=========================="
log
log "Process ID:      ${PID}"
log "Process binary:  ${BINARY}"
log
if [ $WHOAMI == 'root' ]; then
  log "Script user:     root"
elif [ $WHOAMI == $PROC_USERNAME ]; then
  log "Script user:     same user as process $PID"
fi
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

log "Recording /proc/$PID/limits"
cat /proc/$PID/limits > proc-${PID}-limits

log "Recording 'top' output (30 seconds)"
for i in {1..6}; do
  echo
  echo
  top -b -n 1
  sleep 5
done > top.out

log "Recording 'top' output for process $PID (30 seconds)"
for i in {1..6}; do
  echo
  echo
  top -H -p $PID -b -n 1
  sleep 5
done > top-${PID}.out

if [ ! -z $WORKING_DIR ]; then
  if [ -d $WORKING_DIR/var ]; then
    log "Recording 'df' output for ${WORKING_DIR}/var"
    df -kh $WORKING_DIR/var > df.out
  else
    log "Recording 'df' output for ${WORKING_DIR}"
    df -kh $WORKING_DIR > df.out
  fi
else
  log "Skipping 'df' output (process's working directory unknown)"
fi

if command -v free >/dev/null 2>&1; then
  log "Recording 'free' output"
  free -h > free.out
else
  log "Skipping 'free' output (procps package required)"
fi

if command -v vmstat >/dev/null 2>&1; then
  log "Recording 'vmstat' output (30 seconds)"
  vmstat -S m 1 30 > vmstat.out
else
  log "Skipping 'vmstat' output (procps package required)"
fi

if [ -x "$DFW" ]; then
  log "Recording 'dfw info' output"
  $DFW info > dfw-info.out 2>&1
  log "Recording 'dfw status' output"
  $DFW status > dfw-status.out 2>&1
  log "Recording 'dfw versions' output"
  $DFW versions > dfw-versions.out 2>&1
else
  log "Skipping Caplin Deployment Framework reports (dfw command not found)"
fi

if [ $GDB_INSTALLED -eq 0 ]; then
  log "Skipping GDB thread backtraces (gdb package required)"
elif [ $SELINUX_DENY_PTRACE -eq 1 ]; then
  log "Skipping GDB thread backtraces (prohibited by SELINUX deny_ptrace)"
elif [ $YAMA_PTRACE_SCOPE -ne 0 -a $WHOAMI == $PROC_USERNAME ]; then
  log "Skipping GDB thread backtraces (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)"
elif [ $YAMA_PTRACE_SCOPE -eq 3 ]; then
  log "Skipping GDB thread backtraces (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)"
else
  for i in {1..3}; do
    log "${i}/3: Dumping GDB thread backtraces for process $PID"
    gdb -p $PID --quiet \
      -ex "set confirm off" \
      -ex "set logging file ${CMD}-backtrace-$(date +%Y%m%d%H%M%S).out" \
      -ex "set logging on" \
      -ex "set pagination off" \
      -ex "thread apply all bt full" \
      -ex "detach" \
      -ex "quit" > /dev/null 2>> diagnostics.log
    if [ $i -lt 3 ]; then
      log "  Sleeping for 10 seconds..."
      sleep 10
    fi
  done
fi

if command -v jcmd >/dev/null 2>&1; then
  if jcmd -l | grep "^$PID " > /dev/null 2>&1; then
    if [ $WHOAMI == 'root' ]; then
      JCMD="sudo -u $PROC_USERNAME $(which jcmd)"
    else
      JCMD="jcmd"
    fi
    log "Recording JVM stack trace"
    $JCMD $PID Thread.print > jvm-stacktrace 2>> diagnostics.log
    log "Recording JVM heap info"
    $JCMD $PID GC.heap_info > jvm-heapinfo 2>> diagnostics.log
    if [ $RUN_JVM_CLASS_HISTOGRAM -eq 1 ]; then
      log "Recording JVM class histogram"
      $JCMD $PID GC.class_histogram -all > jvm-class-histogram 2>> diagnostics.log
    fi
    if [ $RUN_JVM_HEAP -eq 1 ]; then
      DISK_SPACE=$(df -Pk . | awk 'NR==2 {print $4}')
      DISK_SPACE=$(( $DISK_SPACE / 1024 ))
      HEAP_SIZE=$($JCMD $PID GC.heap_info | grep -E --only-matching 'used [0-9]+K' | cut -d' ' -f2 | tr K ' ' | head -n2 | awk '{s+=$1} END {printf "%.0f", s}')
      HEAP_SIZE=$(( $HEAP_SIZE / 1024 ))
      log "  Estimated heap-file size: ${HEAP_SIZE}MB"
      log "  Available disk space: ${DISK_SPACE}MB"
      if [ $DISK_SPACE -gt $HEAP_SIZE ]; then
        $JCMD $PID GC.heap_dump -all $(pwd)/jvm-heap.hprof >> diagnostics.log 2>&1
      else
        log "  Not enough disk space to dump JVM heap"
        log "  Aborting dump"
      fi
    fi
    log "Recording JVM properties"
    $JCMD $PID VM.system_properties > jvm-props 2>> diagnostics.log
    log "Recording JVM flags"
    $JCMD $PID VM.flags > jvm-flags 2>> diagnostics.log
    log "Recording JVM performance counters"
    $JCMD $PID PerfCounter.print > jvm-perfcounter 2>> diagnostics.log
    if command -v jstat > /dev/null 2>&1; then
      if [ $WHOAMI == 'root' ]; then
        JSTAT="sudo -u $PROC_USERNAME $(which jstat)"
      else
        JSTAT="jstat"
      fi
      log "Recording JVM jstat GC output"
      $JSTAT -gc $PID > jvm-jstat-gc 2>> diagnostics.log
      $JSTAT -gcutil $PID > jvm-jstat-gcutil 2>> diagnostics.log
    else
      log "Skipping JVM jstat statistics (jstat utility not found)"
    fi
  else
    log "Skipping JVM diagnostics (process $PID has no JVM)"
  fi
else
  log "Skipping JVM diagnostics (jcmd utility not found)"
fi

if [ $RUN_STRACE -eq 0 ]; then
  # Fail silently (strace diagnostic is optional)
  :
elif ! command -v strace > /dev/null 2>&1; then
  log "Skipping 'strace' output (strace package required)"
elif [ $SELINUX_DENY_PTRACE -eq 1 ]; then
  log "Skipping 'strace' output (prohibited by SELINUX deny_ptrace)"
elif [ $YAMA_PTRACE_SCOPE -ne 0 -a $WHOAMI == $PROC_USERNAME ]; then
  log "Skipping 'strace' output (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)"
elif [ $YAMA_PTRACE_SCOPE -eq 3 ]; then
  log "Skipping 'strace' output (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)"
else
  log "Recording 'strace' output for process $PID (10 seconds)"
  timeout 20 strace -ff -tt -o $CMD-strace -p $PID >/dev/null 2>&1
  log "Recording 'strace' summary output for process $PID (10 seconds)"
  timeout 20 strace -c -o $CMD-strace-summary -p $PID >/dev/null 2>&1
fi


if [ $GDB_INSTALLED -eq 0 ]; then
  log "Skipping GDB core dump (gdb package required)"
elif [ $SELINUX_DENY_PTRACE -eq 1 ]; then
  log "Skipping GDB core dump (prohibited by SELINUX deny_ptrace)"
elif [ $YAMA_PTRACE_SCOPE -ne 0 -a $WHOAMI == $PROC_USERNAME ]; then
  log "Skipping GDB core dump (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)"
elif [ $YAMA_PTRACE_SCOPE -eq 3 ]; then
  log "Skipping GDB core dump (prohibited by ptrace_scope $YAMA_PTRACE_SCOPE)"
else
  PROC_MEMORY=$(ps -o vsz= -q $PID)
  PROC_MEMORY=$(( $PROC_MEMORY / 1024 ))
  DISK_SPACE=$(df -Pk . | awk 'NR==2 {print $4}')
  DISK_SPACE=$(( $DISK_SPACE / 1024 ))
  log "Dumping GDB core file for process $PID"
  log "  Estimated core-file size: ${PROC_MEMORY}MB"
  log "  Available disk space: ${DISK_SPACE}MB"
  if [ $DISK_SPACE -lt $PROC_MEMORY ]; then
    log "  Not enough disk space to dump core file"
    log "  Aborting dump"
  else
    gcore -o ${CMD}.core $PID >/dev/null 2>&1
    if [ ! -e $CORE ]; then
      log "  Core dump failed (core file '${CORE}' not found)"
    else
      log "  Core dumped to ${CORE}"
      log "  Getting thread backtraces from ${CORE}"
      gdb $BINARY -c $CORE --quiet \
        -ex "set confirm off" \
        -ex "set logging file ${CORE}.backtrace.out" \
        -ex "set logging on" \
        -ex "set pagination off" \
        -ex "thread apply all bt full" \
        -ex "quit" > /dev/null 2>> diagnostics.log
      log "  Getting list of libraries referenced by $CORE"
      gdb $BINARY -c $CORE --quiet \
        -ex "set confirm off" \
        -ex "set logging file libs-list.out" \
        -ex "set logging on" \
        -ex "set pagination off" \
        -ex "info sharedlibrary" \
        -ex "quit" > /dev/null 2>> diagnostics.log
      log "  Copying libraries referenced by $CORE"
      grep "^0x" ./libs-list.out | awk '{if ($5 != "")print $5}' &> libs-list.txt
      cat libs-list.txt | sed "s/\/\.\.\//\//g" | xargs tar -chf ${CORE}.libs.tar &> /dev/null
    fi
  fi
fi

if [ -e $BINARY ]; then
  log "Creating symbolic link to process's binary"
  ln -s $BINARY
else
  log "Cannot create symbolic link to process's binary '$BINARY'"
fi

if [ $WHOAMI == 'root' ]; then
  chown $TEMP_DIR_USER:$TEMP_DIR_GROUP *
fi
log
log "DONE"
log
log "Files collected:"
for f in *; do
  log "  $f"
done
log
log "Archiving files to ${ARCHIVE}.tar.gz"
cd ..
tar -chzf ${ARCHIVE}.tar.gz $(basename ${TEMP_DIR})/*
if [ $WHOAMI == 'root' ]; then
  chown $TEMP_DIR_USER:$TEMP_DIR_GROUP ${ARCHIVE}.tar.gz
fi
rm $TEMP_DIR/*
rmdir $TEMP_DIR
echo
echo "Please login to https://www.caplin.com/account/uploads"
echo "and upload the archive to Caplin Support."
echo
