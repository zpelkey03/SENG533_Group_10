#!/bin/bash

CYBERA_IP="10.1.6.21"
JMETER_PATH=~/apache-jmeter-5.6.3/bin/jmeter
DURATION=180 # 3 minutes per step is enough for Phase 1
SSH="ssh -i ~/will_teastore_key.key ubuntu@$CYBERA_IP"

mkdir -p ./results

# Limit CPU cores at the VM level by taking cores offline via the Linux kernel.
# CPU0 cannot be offlined (it's the boot CPU), so we always keep it.
# For N CPUs: keep cpu0..cpu(N-1) online, offline the rest.
configure_cpus() {
    local cpu_count
    cpu_count=$(printf "%.0f" "$1")  # convert "2.0" -> 2
    echo "  Setting VM CPU cores to $cpu_count..."
    $SSH "
        total=\$(nproc --all)
        for i in \$(seq 1 \$((total - 1))); do
            if [ \$i -lt $cpu_count ]; then
                echo 1 | sudo tee /sys/devices/system/cpu/cpu\${i}/online > /dev/null
            else
                echo 0 | sudo tee /sys/devices/system/cpu/cpu\${i}/online > /dev/null
            fi
        done
        echo \"  Active CPUs: \$(nproc)\"
    "
}

# Limit total RAM at the VM level by setting MemoryMax on the docker systemd
# service cgroup (cgroup v2). This caps ALL containers combined, not per-container.
# --runtime means the limit is not persisted across reboots.
configure_ram() {
    local mem_limit
    mem_limit="${1^^}"  # "4g" -> "4G" (systemd unit suffix)
    echo "  Setting Docker service memory limit to $mem_limit..."
    $SSH "sudo systemctl set-property --runtime docker.service MemoryMax=$mem_limit"
}

# Bring all CPUs back online and remove the memory cap after the experiment.
restore_resources() {
    echo "--- Restoring all VM resources ---"
    $SSH "
        total=\$(nproc --all)
        for i in \$(seq 1 \$((total - 1))); do
            echo 1 | sudo tee /sys/devices/system/cpu/cpu\${i}/online > /dev/null
        done
        sudo systemctl set-property --runtime docker.service MemoryMax=infinity
        echo \"  Restored. Active CPUs: \$(nproc)\"
    "
}

# Phase 1: Vertical Scaling Matrix
experiments=(
    "run1 1.0 4g"
    "run2 1.0 8g"
    "run3 2.0 4g"
    "run4 2.0 8g"
    "run5 3.0 4g"
    "run6 3.0 8g"
    "run7 4.0 4g"
    "run8 4.0 8g"
)

# User Classes
classes=("browsing" "selection" "transaction" "recommendation")

# THE STEPS: Number of concurrent users
user_steps=(20 40 60 80 100)

for exp in "${experiments[@]}"; do
    read run cpu mem <<< "$exp"

    echo "--- CONFIGURING HARDWARE: $run ($cpu CPUs, $mem RAM) ---"
    configure_cpus "$cpu"
    configure_ram "$mem"
    sleep 5  # let the kernel settle before starting load

    for class in "${classes[@]}"; do
        for users in "${user_steps[@]}"; do
            echo "TESTING: $run | CLASS: $class | USERS: $users"

            PREFIX="${run}_${class}_U${users}"
            $SSH "nohup ~/SENG533_Group_10/monitor.sh docker_stats_${PREFIX}.csv </dev/null >/dev/null 2>&1 &"

            # Use -l to create a unique log for EVERY step
            $JMETER_PATH -n -t class_${class}.jmx \
                -Jhostname=$CYBERA_IP \
                -JnumUser=$users \
                -JrampUp=10 \
                -Jduration=$DURATION \
                -Jport=8080 \
                -l ./results/jmeter_results_${run}_${class}_U${users}.jtl

            $SSH "pkill -f monitor.sh"

            scp -i ~/will_teastore_key.key ubuntu@$CYBERA_IP:~/docker_stats_${PREFIX}.csv ./results/
            $SSH "rm ~/docker_stats_${PREFIX}.csv"

            echo "Cooling down..."
            sleep 20
        done
    done
done

restore_resources
