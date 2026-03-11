#!/bin/bash

CYBERA_IP="<YOUR_TEASTORE_VM_IP>"
JMETER_PATH="./bin/jmeter" # Update to your JMeter path
USERS=100
DURATION=300 # 5 minutes

# Phase 1: Vertical Scaling Matrix
# Run Name | CPUs | RAM
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

for exp in "${experiments[@]}"; do
    read run cpu mem <<< "$exp"
    
    echo "--- CONFIGURING HARDWARE: $run ($cpu CPUs, $mem RAM) ---"
    # Update Docker limits on remote host
    ssh ubuntu@$CYBERA_IP "docker update --cpus $cpu --memory $mem teastore-webui teastore-persistence teastore-auth teastore-image teastore-recommender"
    
    for class in "${classes[@]}"; do
        echo "Starting $class test for $run..."
        
        $JMETER_PATH -n -t class_${class}.jmx \
            -Jhostname=$CYBERA_IP \
            -JnumUser=$USERS \
            -JrampUp=20 \
            -Jduration=$DURATION \
            -l results_${run}_${class}.jtl
            
        echo "Cooldown..."
        sleep 30
    done
done