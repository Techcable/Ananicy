#!/bin/bash
################################################################################
# Ananicy - is Another auto nice daemon, with community rules support
# Configs are placed under /etc/ananicy.d/

################################################################################
# Define some fuctions
INFO(){ echo -n "INFO: "; echo "$@" ;}
WARN(){ echo -n "WARN: "; echo "$@" ;}
ERRO(){ echo -n "ERRO: "; echo -n "$@" ; echo " Abort!"; exit 1;}

################################################################################
# Check DIR_CONFIGS
DIR_CONFIGS=/etc/ananicy.d/
INFO "Check $DIR_CONFIGS dir"
[ -d "$DIR_CONFIGS" ] || ERRO "Config dir $DIR_CONFIGS doesn't exist!"

################################################################################
# Load all rule file names
INFO "Search rules"
CONFIGS=( $(find -P $DIR_CONFIGS -name "*.rules" -type f) )
[ "0" != "${#CONFIGS[@]}" ] || ERRO "Config dir: $DIR_CONFIGS are empty!"

################################################################################
# Return specified line of file, ignore comments
read_line(){
    FILE="$1" NUM=$2  # Read line | remove comments | remove unsafe symbols
    sed "${NUM}q;d" $FILE | cut -d'#' -f1 | tr -d '()`$'
}

################################################################################
# Dedup rules
declare -A RULE_CACHE_TMP
INFO "Read rules to buffer"
for config in "${CONFIGS[@]}"; do
    LINE_COUNT=$(wc -l < "$config")
    for line_number in $(seq 1 $LINE_COUNT); do
        LINE="$(read_line $config $line_number)"
        [ -z "$LINE" ] && continue
        for COLUMN in $LINE; do
            case "$COLUMN" in
                NAME=*)
                    NAME="${COLUMN//NAME=/}"
                    [ -z "$NAME" ] && \
                        ERRO "$config:$line_number NAME are empty!"
                    RULE_CACHE_TMP["$NAME"]="$LINE"
                ;;
            esac
        done
    done
done

unset CONFIGS
################################################################################
# Compile rules
INFO "Compile rules to cache"
RULE_CACHE=()
for LINE in "${RULE_CACHE_TMP[@]}"; do
    # Check if line do something
    case "$LINE" in
        *NICE=*)    : ;;
        *IOCLASS=*) : ;;
        *IONICE=*)  : ;;
        *) continue ;;
    esac

    # Check if data in line are valid
    IOCLASS="" IONICE=""
    for COLUMN in $LINE; do
        case "$COLUMN" in
            NICE=*)
                NICE="${COLUMN//NICE=/}"
                if [[ "$NICE" -gt 20 ]] || [[ -19 -gt "$NICE" ]]; then
                    WARN "Nice must be in range -19..20 (line ignored): $LINE"
                    unset LINE
                fi
            ;;
            IONICE=*)
                IONICE="${COLUMN//IONICE=/}"
                [[ $IONICE =~ [0-7] ]] || {
                    WARN "IOnice/IOprio allowed only in range 0-7 (line ignored): $LINE"
                    unset LINE
                }
            ;;
            IOCLASS=*)
                IOCLASS="${COLUMN//IOCLASS=/}"
                [[ $IOCLASS =~ (idle|realtime|best-effort) ]] || {
                    WARN "IOclass (case sensitive) support only (idle|realtime|best-effort) (line ignored): $LINE"
                    unset LINE
                }
            ;;
        esac
    done

    if [ "$IOCLASS" == "idle" ] && [ ! -z $IONICE ]; then
        WARN "IOnice can't use IOclass idle + ionice/ioprio (line ignored): $LINE"
        continue
    fi

    RULE_CACHE=( "${RULE_CACHE[@]}" "$LINE" )
done
unset RULE_CACHE_TMP

[ "0" == "${#RULE_CACHE[@]}" ] && ERRO "No rule is enabled!"

INFO "Initialization completed"
echo "---"

################################################################################
# Show cached information
show_cache(){
    INFO "Dump compiled rules"
    {
        for cache_line in "${RULE_CACHE[@]}"; do
            echo "$cache_line"
        done
    } | sort | column -t
}

trap "{ show_cache; }" SIGUSR1

################################################################################
# pgrep wrapper for future use
pgrep_w(){ pgrep -w "$@"; }

################################################################################
# Helper for wrapper_renice()
nice_of_pid(){
    # 19 column in stat is a nice
    # But in some cases (name of process have a spaces)
    # It's break so.. use long solution
    stat=( $(sed 's/) . /:/g' /proc/$1/stat | cut -d':' -f2) )
    echo ${stat[15]}
}

################################################################################
# Nice handler for process name
wrapper_renice(){
    export NAME="$1" NICE="$2"
    [ -z $NICE ] && return
    for pid in $( pgrep_w "$NAME" ); do
        C_NICE=$(nice_of_pid $pid)
        if [ "$C_NICE" != "$NICE" ]; then
            renice -n $NICE -p $pid &> /dev/null && \
                INFO "Process ${NAME}[$pid] cpu nice: $C_NICE -> $NICE"
        fi
    done
}

################################################################################
# Helpers for wrapper_ionice
ioclass_of_pid(){ ionice -p $1 | cut -d':' -f1; }
ionice_of_pid(){ ionice -p $1 | cut -d':' -f2 | tr -d ' prio'; }

################################################################################
# IONice handler for process name
wrapper_ionice(){
    export NAME="$1" IOCLASS="$2" IONICE="$3"
    [ "$IOCLASS" == "NULL" ] && [ -z "$IONICE" ] && return

    for pid in $( pgrep_w "$NAME" ); do
        C_IOCLASS=$(ioclass_of_pid $pid)
        C_IONICE=$(ionice_of_pid $pid)
        if [ "$IOCLASS" != "NULL" ] && [ "$C_IOCLASS" != "$IOCLASS" ]; then
            ionice -c "$IOCLASS" -p "$pid" && \
                INFO "Process ${NAME}[$pid] ioclass: $C_IOCLASS -> $IOCLASS"
        fi
        if [ ! -z "$IONICE" ] && [ "$C_IONICE" != "$IONICE" ]; then
            ionice -n "$IONICE" -p "$pid" && \
                INFO "Process ${NAME}[$pid] ionice: $C_IONICE -> $IONICE"
        fi
    done
}

check_root_rights(){ [ "$UID" == "0" ] || ERRO "Script must be runned as root!"; }

main_pid_get(){
    PIDS=( $(pgrep ananicy | grep -v $$) )
    [ -z "${PIDS[0]}" ] && ERRO "Can't find running Ananicy"
    echo "${PIDS[@]}"
}

check_schedulers(){
    for disk_path in /sys/class/block/*; do
        disk_name=$(basename $disk_path)
        scheduler_path="$disk_path/queue/scheduler"
        [ ! -f $scheduler_path ] && continue
        grep -q '\[cfq\]' $scheduler_path || \
            WARN "Disk $disk_name not used cfq scheduler IOCLASS/IONICE will not work on it!"
    done
}

show_help(){
    echo "$0 start - start daemon"
    echo "$0 dump rules cache - daemon will dump rules cache to stdout"
    echo "$0 dump rules parsed - generate and dump rules cache to stdout"
}

main_process(){
    for LINE in "${RULE_CACHE[@]}"; do
        NAME="" NICE="" IOCLASS="NULL" IONICE=""
        for COLUMN in $LINE; do
            case "$COLUMN" in
                NAME=*)    NAME="${COLUMN//NAME=/}"         ;;
                NICE=*)    NICE="${COLUMN//NICE=/}"         ;;
                IONICE=*)  IONICE="${COLUMN//IONICE=/}"     ;;
                IOCLASS=*) IOCLASS="${COLUMN//IOCLASS=/}"   ;;
            esac
        done
        wrapper_renice "$NAME" "$NICE"
        wrapper_ionice "$NAME" "$IOCLASS" "$IONICE"
    done
}

################################################################################
# Main process
case $1 in
    start)
        check_root_rights
        check_schedulers
        INFO "Start main process"
        RUN_FREQ=15
        while sleep $RUN_FREQ; do
            main_process;
        done
    ;;
    dump)
        case "$2" in
            rules)
                case "$3" in
                    cache)
                        check_root_rights
                        for pid in $(main_pid_get); do
                            [ -d /proc/$pid ] && \
                                kill -s SIGUSR1 $pid
                        done
                    ;;
                    parsed) show_cache ;;
                    *) show_help ;;
                esac
            ;;
            *) show_help ;;
        esac
    ;;
    *) show_help ;;
esac
