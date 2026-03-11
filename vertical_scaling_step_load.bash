#!/bin/bash

CYBERA_IP="<YOUR_TEASTORE_VM_IP>"
JMETER_PATH="./bin/jmeter"
DURATION=180 # 3 minutes per step is enough for Phase 1

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
    ssh ubuntu@$CYBERA_IP "docker update --cpus $cpu --memory $mem teastore-webui teastore-persistence teastore-auth teastore-image teastore-recommender"

    for class in "${classes[@]}"; do
        for users in "${user_steps[@]}"; do
            echo "TESTING: $run | CLASS: $class | USERS: $users"

            # Use -l to create a unique log for EVERY step
            $JMETER_PATH -n -t class_${class}.jmx \
                -Jhostname=$CYBERA_IP \
                -JnumUser=$users \
                -JrampUp=10 \
                -Jduration=$DURATION \
                -l results_${run}_${class}_U${users}.jtl

            echo "Cooling down..."
            sleep 20
        done
    done
done