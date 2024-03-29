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

VERSION=0.0.12

SCRIPT_FILE=$(basename "$0")
SCRIPT_DIR=$(dirname "$0")

HELP="$(cat << EOF

NAME
  $SCRIPT_FILE - run diagnostics on a Caplin process

SYNOPSIS
  $SCRIPT_FILE [options] pid

    [options]:  see OPTIONS below
    pid:        process identifier

DEPENDENCIES
  - CentOS/RHEL 6 or 7
  - GNU Debugger ('gdb' RPM package)
  - OpenJDK 8 ('java-1.8.0-openjdk-devel' RPM package)

DESCRIPTION
  Collates diagnostic information for a Caplin process, without
  terminating the process.

  This script captures the following diagnostics:
    - Operating system name and version
    - Process limits
    - User limits
    - 'top' output for the system (5 seconds)
    - 'top' output for the process (5 seconds)
    - 'df' output for the process's <working-dir>/var directory
    - 'free' output
    - 'vmstat' output (5 seconds)
    - If the process's binary is in a Caplin Deployment Framework:
      - 'dfw info' output
      - 'dfw status' output
      - 'dfw versions' output
    - If the process has a Java virtual machine (JVM) and JDK tools are available:
      - 'jcmd <pid> Thread.print' output
      - 'jcmd <pid> GC.heap_info' output
      - 'jcmd <pid> VM.system_properties' output
      - 'jcmd <pid> VM.flags' output
      - 'jcmd <pid> PerfCounter.print' output
      - 'jstat -gc <pid>' output
      - 'jstat -gcutil <pid>' output
    - If the GNU Debugger is installed:
      - GDB thread backtrace

OPTIONS
  -h --help     Display this message

  --gcore       Include the optional GDB core dump (gcore)
                Enable only if requested by Caplin Support

  --jvm-heap    Include the optional JVM heap dump diagnostic.
                Enable only if requested by Caplin Support.

  --jvm-class-histogram
                Include the optional JVM class histogram diagnostic.
                Enable only if requested by Caplin Support.

  --strace      Include the optional strace diagnostic.
                Enable only if requested by Caplin Support.
  
  -v --version  Print the script version and exit

EOF
)"

RUN_STRACE=0
RUN_JVM_HEAP=0
RUN_JVM_CLASS_HISTOGRAM=0
RUN_GCORE=0
SHOW_HELP=0
SHOW_VERSION=0
POSITIONAL=()
while [[ $# -gt 0 ]]
do
  key="$1"
  case "$key" in
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
      --gcore)
      RUN_GCORE=1
      shift
      ;;
      -v|--version)
      SHOW_VERSION=1
      shift
      ;;
      *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [ $SHOW_HELP -eq 1 ]; then
  printf '%s\n\n' "$HELP"
  exit 0
fi
if [ $SHOW_VERSION -eq 1 ] ; then
  printf '%s\n' "$VERSION"
  exit 0
fi
if [ $# -ne 1 ]; then
  printf '%s\n\n' "$HELP"
  exit 1
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
MY_EUID=$(id --user)
MY_RUID=$(id --user --real)
MY_EUSER=$(id --user --name)
MY_RUSER=$(id --user --name --real)
PROCESS_EUID=$(ps --pid ${PID} --no-headers --format euser)
PROCESS_RUID=$(ps --pid ${PID} --no-headers --format ruser)
PROCESS_SUID=$(ps --pid ${PID} --no-headers --format suser)
PROCESS_FUID=$(ps --pid ${PID} --no-headers --format fuser)
PROCESS_EUSER=$(ps --pid ${PID} --no-headers --format euser)
PROCESS_RUSER=$(ps --pid ${PID} --no-headers --format ruser)
PROCESS_SUSER=$(ps --pid ${PID} --no-headers --format suser)
PROCESS_FUSER=$(ps --pid ${PID} --no-headers --format fuser)
PROCESS_MEMORY=$(ps -o vsz= -q $PID)
PROCESS_MEMORY=$(( $PROCESS_MEMORY / 1024 ))

if [ "$MY_EUSER" != 'root' -a "$MY_EUSER" != "$PROCESS_EUSER" ]; then
  echo "This script must be run as user '$PROCESS_EUSER' (the same user as process $PID) or root"
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
  echo "$(date --iso-8601=seconds)   $1" | tee -a diagnostics.log
}

HOSTNAME=$(hostname -s)
CMD=$(ps --pid $PID --no-headers --format comm)
CORE=${CMD}.core.${PID}
ARCHIVE=diagnostics-${HOSTNAME}-${CMD}-${PID}-$(date +%Y%m%d%H%M%S)
DISK_SPACE=$(df -Pk . | awk 'NR==2 {print $4}')
DISK_SPACE=$(( $DISK_SPACE / 1024 ))
DUMPABLE=0
BINARY=""
BINARY_DIR=""
WORKING_DIR=""
DFW=""
if [ -r /proc/$PID/exe ] ; then
  DUMPABLE=1
  BINARY=$(readlink -e /proc/${PID}/exe)
  BINARY_DIR=$(dirname "$BINARY")
  WORKING_DIR=$(pwdx $PID | cut -d' ' -f2)
  DFW=$(searchparents "$BINARY_DIR" dfw)
  if [ -n "$DFW" ]; then
    DFW=$(readlink -e "$DFW")
  fi
fi
if [ "$MY_EUSER" == 'root' ]; then
  # Use the process user's JAVA_HOME
  export JAVA_HOME=$(su -l -c 'echo $JAVA_HOME' "$PROCESS_EUSER")
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
if command -v getenforce >/dev/null 2>&1; then
  SELINUX_MODE=$(getenforce)
else
  SELINUX_MODE="Disabled"
fi


# Warn the user when specific tests cannot run
declare -a WARNINGS
if [ $GDB_INSTALLED -eq 0 ]; then
  WARNINGS+=("GDB thread backtrace (requires 'gdb' package)")
  if [ $RUN_GCORE -eq 1 ]; then
    WARNINGS+=("GDB core dump (requires 'gdb' package)")
  fi
fi
if [ $DUMPABLE -eq 0 ] ; then
  WARNINGS+=("GDB thread backtrace (user '$MY_EUSER' cannot read /proc/$PID/exe, which indicates a failed ptrace access mode check. Try running this script as root.)")
  WARNINGS+=("Caplin DFW command output (user '$MY_EUSER' cannot read /proc/$PID/exe to determine the path to the $CMD binary. Try running this script as root.)")
  if [ $RUN_GCORE -eq 1 ]; then
    WARNINGS+=("GDB core dump (user '$MY_EUSER' cannot read /proc/$PID/exe, which indicates a failed ptrace access mode check. Try running this script as root.)")
  fi
fi
if [ $SELINUX_DENY_PTRACE -eq 1 ]; then
  if [ $RUN_STRACE -eq 1 ]; then
    WARNINGS+=("strace (prohibited by SELINUX deny_ptrace)")
  fi
  WARNINGS+=("GDB thread backtrace (prohibited by SELINUX deny_ptrace)")
  if [ $RUN_GCORE -eq 1 ]; then
    WARNINGS+=("GDB core dump (prohibited by SELINUX deny_ptrace)")
  fi
fi
if ! command -v strace >/dev/null 2>&1; then
  if [ $RUN_STRACE -eq 1 ]; then
    WARNINGS+=("strace (requires 'strace' package)")
  fi
fi
if [ $YAMA_PTRACE_SCOPE -eq 3 ]; then
  WARNINGS+=("GDB thread backtrace (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)")
  if [ $RUN_GCORE -eq 1 ]; then
    WARNINGS+=("GDB core dump (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)")
  fi
  if [ $RUN_STRACE -eq 1 ]; then
    WARNINGS+=("strace (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)")
  fi
fi
if [ $YAMA_PTRACE_SCOPE -gt 0 -a $YAMA_PTRACE_SCOPE -lt 3 -a $MY_EUSER != 'root' ]; then
  WARNINGS+=("GDB thread backtrace (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)")
  if [ $RUN_GCORE -eq 1 ]; then
    WARNINGS+=("GDB core dump (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)")
  fi
  if [ $RUN_STRACE -eq 1 ]; then
    WARNINGS+=("strace (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)")
  fi
fi
if [ $DISK_SPACE -lt $PROCESS_MEMORY ]; then
  WARNINGS+=("GDB core dump (insufficient free disk space -- need at least ${PROCESS_MEMORY}MB)")
fi
if ! command -v jcmd >/dev/null 2>&1; then
  WARNINGS+=("JVM diagnostics (jcmd command not found in executable path)")
fi
if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo
  echo "Process ID: ${PID}"
  echo "Process binary: ${CMD}"
  echo "Process binary path: ${BINARY:-?}"
  echo "Process effective user: ${PROCESS_EUSER}"
  echo "Process real user: ${PROCESS_RUSER}"
  echo "Process saved user: ${PROCESS_SUSER}"
  echo "Script effective user: ${MY_EUSER}"
  echo "Script real user: ${MY_RUSER}"
  if [ -r /proc/sys/kernel/yama/ptrace_scope ]; then
    echo "Yama ptrace_scope: ${YAMA_PTRACE_SCOPE}"
  fi
  if [ -r /sys/fs/selinux/booleans/deny_ptrace ]; then
    echo "SELINUX mode: ${SELINUX_MODE}"
    echo "SELINUX deny_ptrace: ${SELINUX_DENY_PTRACE}"
  fi
  echo
  echo "The following diagnostics will be skipped:"
  for warning in "${WARNINGS[@]}"; do
    echo "  - $warning"
  done
  echo
  read -p "Continue? [Y/N]: " RESPONSE
  if [ "$RESPONSE" != 'y' -a "$RESPONSE" != 'Y' ]; then
    echo
    exit 1
  fi
  echo
fi

if ! mkdir -p "$ARCHIVE"; then
  echo "Could not create temporary directory $ARCHIVE"
  exit 1
fi
TEMP_DIR=$(readlink -e "$ARCHIVE")
TEMP_DIR_USER=$(stat . -c %U)
TEMP_DIR_GROUP=$(stat . -c %G)
if [ "$MY_EUSER" == 'root' ]; then
  chown "$TEMP_DIR_USER":"$TEMP_DIR_GROUP" "$TEMP_DIR"
fi
cd "$TEMP_DIR"

echo
log "Caplin Process Diagnostics ${VERSION}"
log "================================="
log
log "Process ID: ${PID}"
log "Process binary: ${CMD}"
log "Process binary path: ${BINARY:-?}"
log "Process effective user: ${PROCESS_EUSER}"
log "Process real user: ${PROCESS_RUSER}"
log "Process saved user: ${PROCESS_SUSER}"
log "Script effective user: ${MY_EUSER}"
log "Script real user: ${MY_RUSER}"
log "Script temp dir: ./$ARCHIVE"
if [ -r /proc/sys/kernel/yama/ptrace_scope ]; then
  log "Yama ptrace_scope: ${YAMA_PTRACE_SCOPE}"
fi
if [ -r /sys/fs/selinux/booleans/deny_ptrace ]; then
  log "SELINUX mode: ${SELINUX_MODE}"
  log "SELINUX deny_ptrace: ${SELINUX_DENY_PTRACE}"
fi
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
  cat "$f" > "$(echo $f | cut -c 2- | tr / -)"
done
if [ -d /etc/abrt ]; then
  log "Recording config for Red Hat ABRT"
  tar --ignore-failed-read -czf ABRT-config.tar.gz /etc/abrt /etc/libreport
fi

if [ -r /etc/security/limits.conf ]; then
  log "Recording /etc/security/limits.conf"
  cat /etc/security/limits.conf >> limits.conf
  find /etc/security/limits.d -name '*.conf' -exec cat {} \; >> limits.conf
fi

log "Recording /proc/$PID/limits"
cat /proc/$PID/limits > proc-${PID}-limits

log "Recording 'top' output (5 seconds)"
for i in {1..5}; do
  echo
  echo
  top -b -n 1
  sleep 1
done > top.out

log "Recording 'top' output for process $PID (5 seconds)"
for i in {1..5}; do
  echo
  echo
  top -H -p $PID -b -n 1
  sleep 1
done > top-${PID}.out

log "Recording available disk space"
df -h > df.out

if command -v free >/dev/null 2>&1; then
  log "Recording 'free' output"
  free -h > free.out
else
  log "Skipping 'free' output (procps package required)"
fi

if command -v vmstat >/dev/null 2>&1; then
  log "Recording 'vmstat' output (5 seconds)"
  vmstat -S m 1 5 > vmstat.out
else
  log "Skipping 'vmstat' output (procps package required)"
fi

if [ $DUMPABLE -eq 0 ]; then
  log "Skipping DFW commands info, status and versions (cannot determine path to ${CMD} binary)"
elif [ -z "$DFW" ]; then
  log "Skipping DFW commands info, status and versions (dfw command not found)"
else
  log "Recording 'dfw info' output"
  "$DFW" info > dfw-info.out 2>&1
  log "Recording 'dfw status' output"
  "$DFW" status > dfw-status.out 2>&1
  log "Recording 'dfw versions' output"
  "$DFW" versions > dfw-versions.out 2>&1
fi

if [ $GDB_INSTALLED -eq 0 ]; then
  log "Skipping GDB thread backtraces (gdb package required)"
elif [ $SELINUX_MODE == 'Enforcing' -a $SELINUX_DENY_PTRACE -eq 1 ]; then
  log "Skipping GDB thread backtraces (prohibited by SELINUX deny_ptrace)"
elif [ $YAMA_PTRACE_SCOPE -ne 0 -a "$MY_EUSER" == "$PROCESS_EUSER" ]; then
  log "Skipping GDB thread backtraces (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)"
elif [ $YAMA_PTRACE_SCOPE -eq 3 ]; then
  log "Skipping GDB thread backtraces (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)"
elif [ $DUMPABLE -eq 0 ]; then
  log "Skipping GDB thread backtraces (cannot read /proc/$PID/exe, which indicates a failed ptrace access mode check)"
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
      log "  Sleeping for 1 second..."
      sleep 1
    fi
  done
fi

if command -v jcmd >/dev/null 2>&1; then
  if jcmd -l | grep "^$PID " > /dev/null 2>&1; then
    if [ "$MY_EUSER" == 'root' ]; then
      JCMD="sudo -u '$PROCESS_EUSER' $(which jcmd)"
    else
      JCMD="jcmd"
    fi
    for i in {1..3}; do
      log "${i}/3: Dumping JVM stack trace for process $PID"
      $JCMD $PID Thread.print -l > jvm-stacktrace-$(date +%Y%m%d%H%M%S).out 2>> diagnostics.log
      if [ $i -lt 3 ]; then
        log "  Sleeping for 1 second..."
        sleep 1
      fi
    done
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
      if [ "$MY_EUSER" == 'root' ]; then
        JSTAT="sudo -u '$PROCESS_EUSER' $(which jstat)"
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
    log "Skipping JVM diagnostics (process $PID has no detectable JVM)"
  fi
else
  log "Skipping JVM diagnostics (jcmd utility not found)"
fi

if [ $RUN_STRACE -eq 0 ]; then
  # Fail silently (strace diagnostic is optional)
  :
elif ! command -v strace > /dev/null 2>&1; then
  log "Skipping 'strace' output (strace package required)"
elif [ $SELINUX_MODE == 'Enforcing' -a $SELINUX_DENY_PTRACE -eq 1 ]; then
  log "Skipping 'strace' output (prohibited by SELINUX deny_ptrace)"
elif [ $YAMA_PTRACE_SCOPE -ne 0 -a "$MY_EUSER" == "$PROCESS_EUSER" ]; then
  log "Skipping 'strace' output (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)"
elif [ $YAMA_PTRACE_SCOPE -eq 3 ]; then
  log "Skipping 'strace' output (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)"
elif [ $DUMPABLE -eq 0 ]; then
  log "Skipping 'strace' output (cannot read /proc/$PID/exe, which indicates a failed ptrace access mode check)"
else
  log "Recording 'strace' output for process $PID (20 seconds)"
  timeout 20 strace -ff -tt -o $CMD-strace -p $PID >/dev/null 2>&1
  log "Recording 'strace' summary output for process $PID (20 seconds)"
  timeout 20 strace -c -o $CMD-strace-summary -p $PID >/dev/null 2>&1
fi

if [ $RUN_GCORE -eq 0 ]; then
  # Fail silently (gcore diagnostic is optional)
  :
elif [ $GDB_INSTALLED -eq 0 ]; then
  log "Skipping GDB core dump (gdb package required)"
elif [ $SELINUX_MODE == 'Enforcing' -a $SELINUX_DENY_PTRACE -eq 1 ]; then
  log "Skipping GDB core dump (prohibited by SELINUX deny_ptrace)"
elif [ $YAMA_PTRACE_SCOPE -ne 0 -a "$MY_EUSER" == "$PROCESS_EUSER" ]; then
  log "Skipping GDB core dump (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)"
elif [ $YAMA_PTRACE_SCOPE -eq 3 ]; then
  log "Skipping GDB core dump (prohibited by Yama kernel module: ptrace_scope $YAMA_PTRACE_SCOPE)"
elif [ $DUMPABLE -eq 0 ]; then
  log "Skipping GDB core dump (cannot read /proc/$PID/exe, which indicates a failed ptrace access mode check)"
else
  PROCESS_MEMORY=$(ps -o vsz= -q $PID)
  PROCESS_MEMORY=$(( $PROCESS_MEMORY / 1024 ))
  DISK_SPACE=$(df -Pk . | awk 'NR==2 {print $4}')
  DISK_SPACE=$(( $DISK_SPACE / 1024 ))
  log "Dumping GDB core file for process $PID"
  log "  Estimated core-file size: ${PROCESS_MEMORY}MB"
  log "  Available disk space: ${DISK_SPACE}MB"
  if [ $DISK_SPACE -lt $PROCESS_MEMORY ]; then
    log "  Not enough disk space to dump core file"
    log "  Aborting dump"
  else
    gcore -o ${CMD}.core $PID >/dev/null 2>&1
    if [ ! -e "$CORE" ]; then
      log "  Core dump failed (core file '${CORE}' not found)"
    else
      log "  Core dumped to ${CORE}"
      if [ -e "$BINARY" ]; then
        log "  Creating symbolic link to process's binary"
        ln -s "$BINARY"
      else
        log "Cannot create symbolic link to process's binary '$BINARY'"
      fi
      log "  Getting thread backtraces from ${CORE}"
      gdb "$BINARY" -c "$CORE" --quiet \
        -ex "set confirm off" \
        -ex "set logging file ${CORE}.backtrace.out" \
        -ex "set logging on" \
        -ex "set pagination off" \
        -ex "thread apply all bt full" \
        -ex "quit" > /dev/null 2>> diagnostics.log
      log "  Getting list of libraries referenced by $CORE"
      gdb "$BINARY" -c "$CORE" --quiet \
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

if [ "$MY_EUSER" == 'root' ]; then
  chown "$TEMP_DIR_USER":"$TEMP_DIR_GROUP" ./*
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
nice -n 10 tar -chzf "${ARCHIVE}.tar.gz" "$ARCHIVE"
if [ $MY_EUSER == 'root' ]; then
  chown "$TEMP_DIR_USER":"$TEMP_DIR_GROUP" "${ARCHIVE}.tar.gz"
fi
rm "$TEMP_DIR"/*
rmdir "$TEMP_DIR"
echo
echo "Please login to https://www.caplin.com/account/uploads"
echo "and upload the archive to Caplin Support."
echo
