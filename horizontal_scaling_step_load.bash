#!/bin/bash
trap 'echo "Script interrupted. Cleaning up..."; exit' INT

# ==========================================
# 1. CONFIGURATION
# ==========================================
LOAD_BALANCER_IP="10.1.3.114"

PEM_KEY="$HOME/new-pk.pem"
JMETER_PATH="$HOME/apache-jmeter-5.6.3/bin/jmeter"

# Test variables
WARMUP_DURATION=30
DURATION=180
NODE_IPS=("10.1.4.120" "10.1.4.248")
CLASSES=("browsing" "selection" "transaction" "recommendation")
USER_STEPS=(20 40 60 80 100)

mkdir -p ./results

echo "Prepping all backend nodes..."
for ip in "${NODE_IPS[@]}"; do
    ssh -i "$PEM_KEY" ubuntu@$ip "mkdir -p ~/SENG533_Group_10"
    scp -i "$PEM_KEY" ./monitor.sh ubuntu@$ip:~/SENG533_Group_10/
    scp -i "$PEM_KEY" ./monitor.sh ubuntu@$ip:~/
    ssh -i "$PEM_KEY" ubuntu@$ip "chmod +x ~/SENG533_Group_10/monitor.sh ~/monitor.sh 2>/dev/null"
done
echo "Nodes prepped!"

# ==========================================
# 2. THE NODE LOOP (1, then 2, then 3 Nodes)
# ==========================================
for num_nodes in 1 2; do
# This loop kills ghost containers on every machine in your list
    for ip in "${NODE_IPS[@]}"; do
        ssh -i "$PEM_KEY" ubuntu@$ip "cd ~/SENG533_Group_10/deployment && sudo docker compose -f docker-compose_default.yaml down>/dev/null 2>&1"
    done
    echo "=================================================="
    echo " CONFIGURING HAPROXY FOR $num_nodes NODE(S)"
    echo "=================================================="

    # Build the HAProxy config
    cat <<EOF > ./temp_haproxy.cfg
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode http
    option httplog
    option dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend http_web
    bind *:80
    mode http
    default_backend rgw

backend rgw
    balance roundrobin
    mode http
    cookie SERVERID insert indirect nocache
EOF

    # Add the active backend servers
    for (( j=0; j<$num_nodes; j++ )); do
        echo "    server node$((j+1)) ${NODE_IPS[$j]}:8080 check cookie node$((j+1))" >> ./temp_haproxy.cfg
    done

    # Upload and restart HAProxy
    scp -i "$PEM_KEY" ./temp_haproxy.cfg ubuntu@$LOAD_BALANCER_IP:~/haproxy.cfg
    ssh -i "$PEM_KEY" ubuntu@$LOAD_BALANCER_IP "sudo mv ~/haproxy.cfg /etc/haproxy/haproxy.cfg && sudo systemctl restart haproxy"
    
    echo "HAProxy restarted. Waiting 5 seconds..."
    sleep 10

    # ==========================================
    # 3. THE JMETER & MONITORING LOOPS
    # ==========================================
    for class in "${CLASSES[@]}"; do
        for users in "${USER_STEPS[@]}"; do
            
            PREFIX="N${num_nodes}_${class}_U${users}"
            echo "--------------------------------------------------"
            echo "PREPARING TEST: $num_nodes Nodes | CLASS: $class | USERS: $users"
            
            # CLEAN SLATE: Restart containers on active nodes to clear memory/state
            echo "Restarting Docker containers on active backend nodes..."
            for (( k=0; k<$num_nodes; k++ )); do
                CURRENT_NODE="${NODE_IPS[$k]}"
                # Note: Adjust the docker restart command if you only want to restart specific containers
                ssh -i "$PEM_KEY" ubuntu@$CURRENT_NODE "cd ~/SENG533_Group_10/deployment && sudo docker compose -f docker-compose_default.yaml up --build --force-recreate -d >/dev/null 2>&1"
                echo "Waiting for WebUI to respond with 200 OK..."
            done
            echo "Waiting for all $num_nodes active WebUI(s) to respond with 200 OK..."
            for (( k=0; k<$num_nodes; k++ )); do
                ACTIVE_IP="${NODE_IPS[$k]}"
                echo "Checking Node $((k+1)) ($ACTIVE_IP)..."
                # We use a subshell to run the timeout check for each specific node
                timeout 300s bash -c "until curl -s -o /dev/null -w '%{http_code}' http://$ACTIVE_IP:8080/tools.descartes.teastore.webui/ | grep -q '200'; do sleep 5; done"
                if [ $? -ne 0 ]; then
                    echo "Node $ACTIVE_IP failed to become healthy in time. Aborting test."
                    exit 1
                fi
            done
            echo "All active nodes are healthy!"
            # WARM UP PHASE: Send silent traffic to build caches
            echo "Warming up application caches for $WARMUP_DURATION seconds..."
            "$JMETER_PATH" -n -t class_${class}.jmx \
                -Jhostname=$LOAD_BALANCER_IP \
                -JnumUser=$users \
                -JrampUp=5 \
                -Jduration=$WARMUP_DURATION \
                -Jport=80 > /dev/null 2>&1
            
            echo "Warmup complete. Starting official recording..."

            # START MONITORING ON ACTIVE BACKEND NODES
            for (( k=0; k<$num_nodes; k++ )); do
                CURRENT_NODE="${NODE_IPS[$k]}"
                ssh -i "$PEM_KEY" ubuntu@$CURRENT_NODE "nohup ~/monitor.sh docker_stats_${PREFIX}_Node$((k+1)).csv </dev/null >/dev/null 2>&1 &"
            done

            # RUN OFFICIAL JMETER TEST
            "$JMETER_PATH" -n -t class_${class}.jmx \
                -Jhostname=$LOAD_BALANCER_IP \
                -JnumUser=$users \
                -JrampUp=10 \
                -Jduration=$DURATION \
                -Jport=80 \
                -l ./results/jmeter_results_${PREFIX}.jtl

            # STOP MONITORING AND DOWNLOAD LOGS
            for (( k=0; k<$num_nodes; k++ )); do
                CURRENT_NODE="${NODE_IPS[$k]}"
                ssh -i "$PEM_KEY" ubuntu@$CURRENT_NODE "pkill -f monitor.sh"
                scp -i "$PEM_KEY" ubuntu@$CURRENT_NODE:~/docker_stats_${PREFIX}_Node$((k+1)).csv ./results/
                ssh -i "$PEM_KEY" ubuntu@$CURRENT_NODE "rm ~/docker_stats_${PREFIX}_Node$((k+1)).csv"
            done

            echo "Test complete. Cooling down..."
            sleep 15
        done
    done
done

rm ./temp_haproxy.cfg
echo "All testing complete!"