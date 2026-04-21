#!/bin/bash

CYBERA_IP="10.1.6.21"
JMETER_PATH=~/apache-jmeter-5.6.3/bin/jmeter
DURATION=180 # 3 minutes per step is enough for Phase 1
SSH="ssh -i ~/will_teastore_key.key ubuntu@$CYBERA_IP"

mkdir -p ./results

# Auto-detect the docker systemd service name on the performance VM once at startup.
# Docker may be installed as "docker.service" (apt) or "snap.docker.dockerd.service" (snap), etc.
echo "Detecting docker service name on $CYBERA_IP..."
DOCKER_SVC=$($SSH "systemctl list-units --type=service --state=running 2>/dev/null \
    | awk '{print \$1}' | grep -i docker | grep -iv containerd | head -1")
if [ -z "$DOCKER_SVC" ]; then
    echo "ERROR: No running docker systemd service found on $CYBERA_IP. Cannot apply RAM limits. Aborting."
    exit 1
fi
echo "  Found docker service: $DOCKER_SVC"

# Limit total resources at the VM level by capping the Docker systemd service.
configure_hardware() {
    local cpu_val="$1"
    local mem_limit="${2^^}"
    
    local cpuset=""
    
    if [ "$cpu_val" == "1.0" ]; then 
        cpuset="0"
    elif [ "$cpu_val" == "2.0" ]; then 
        cpuset="0-1"
    elif [ "$cpu_val" == "3.0" ]; then 
        cpuset="0-2"
    elif [ "$cpu_val" == "4.0" ]; then 
        cpuset="0-3"
    fi

    echo "  Setting Global Docker Limits -> CPU: $cpu_val | RAM: $mem_limit | CPUSET: $cpuset"
    
    # Just pin containers to allowed CPUs and set memory limit
    $SSH "docker update --cpuset-cpus='$cpuset' --memory $mem_limit \
        deployment_webui_1 deployment_image_1 deployment_recommender_1 \
        deployment_auth_1 deployment_persistence_1 deployment_registry_1 \
        deployment_db_1 >/dev/null 2>&1"
}

restore_resources() {
    echo "--- Restoring all VM resources ---"
    $SSH "docker update --cpuset-cpus='0-3' --memory 0 \
        deployment_webui_1 deployment_image_1 deployment_recommender_1 \
        deployment_auth_1 deployment_persistence_1 deployment_registry_1 \
        deployment_db_1 >/dev/null 2>&1"
    echo "  Restored Docker limits to unlimited."
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
user_steps=(5 10 20 40 60 80 100)

for exp in "${experiments[@]}"; do
    read run cpu mem <<< "$exp"

    echo "--- CONFIGURING HARDWARE: $run ($cpu CPUs, $mem RAM) ---"
    configure_hardware "$cpu" "$mem"

    echo "  Restarting TeaStore containers to apply new hardware topology..."
    $SSH "docker restart deployment_image_1  deployment_recommender_1 deployment_registry_1 deployment_persistence_1 deployment_webui_1 deployment_auth_1 deployment_db_1 >/dev/null"

    echo "  Waiting for TeaStore WebUI to finish booting (this may take a while on 4GB runs)..."
    
    until curl -s -f "http://$CYBERA_IP:8080/tools.descartes.teastore.webui/" > /dev/null; do
        echo "    Still booting... waiting 5 seconds."
        sleep 5
    done
    
    echo "  TeaStore is UP! Running Warm-up sequence to pre-heat database connections..."
    for i in {1..10}; do
        curl -s "http://$CYBERA_IP:8080/tools.descartes.teastore.webui/category?category=2" > /dev/null
    done
    
    echo "  Warm-up complete. Giving JVMs 10 seconds to stabilize before load test..."
    sleep 10

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
