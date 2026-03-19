#!/bin/bash
trap 'echo "Script interrupted. Cleaning up tunnels..."; pkill -f "ssh -i.*-L 8080"; exit' INT
# ==========================================
# 1. CONFIGURATION
# ==========================================
LOAD_BALANCER_IP="10.1.3.114"
# Replaced ~ with $HOME inside quotes to prevent pathing errors
PEM_KEY="$HOME/Documents/seng-533-ssh/new/new-pk.pem"
JMETER_PATH="$HOME/Documents/seng-533-ssh/new/jmeter/apache-jmeter-5.6.3/bin/jmeter"
DURATION=180 

NODE_IPS=("10.1.4.120" "10.1.4.248" "10.1.6.82")
CLASSES_1=("browsing" "selection")
CLASSES_2=("transaction" "recommendation")
CLASSES=("transaction" "recommendation") #class2
USER_STEPS=(20 40 60 80 100)

mkdir -p ./results

echo "Opening SSH Tunnel to Load Balancer..."
ssh -i "$PEM_KEY" -f -N -L 8080:127.0.0.1:80 ubuntu@$LOAD_BALANCER_IP

for ip in "${NODE_IPS[@]}"; do
    echo "Updating and fixing monitor.sh on $ip..."
    
    # 1. Make sure the target folder exists
    ssh -i "$PEM_KEY" ubuntu@$ip "mkdir -p ~/SENG533_Group_10"
    
    # 2. Upload the script to both locations
    scp -i "$PEM_KEY" ./monitor.sh ubuntu@$ip:~/SENG533_Group_10/
    scp -i "$PEM_KEY" ./monitor.sh ubuntu@$ip:~/
    
    # 3. Make them both executable
    ssh -i "$PEM_KEY" ubuntu@$ip "chmod +x ~/SENG533_Group_10/monitor.sh ~/monitor.sh 2>/dev/null"
done

echo "All nodes updated and fully prepped!"


# ==========================================
# 2. THE NODE LOOP (1, then 2, then 3 Nodes)
# ==========================================
for num_nodes in 3 2 1; do
    echo "=================================================="
    echo " CONFIGURING HAPROXY FOR $num_nodes NODE(S)"
    echo "=================================================="

    # Step A: Build the base HAProxy config
    cat <<EOF > ./temp_haproxy.cfg
global
    log /dev/log    local0
    log /dev/log    local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    ca-base /etc/ssl/certs
    crt-base /etc/ssl/private
    ssl-default-bind-ciphers ECDH+AESGCM:DH+AESGCM:ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES:RSA+AESGCM:RSA+AES:!aNULL:!MD5:!DSS
    ssl-default-bind-options no-sslv3

defaults
    log global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

frontend http_web
    bind *:80
    mode http
    default_backend rgw

frontend rgw-https
    bind *:443 ssl crt /etc/ssl/private/example.com.pem
    mode http
    default_backend rgw

backend rgw
    balance roundrobin
    mode http
    # This inserts a cookie to tie the user to a specific node
    cookie SERVERID insert indirect nocache
EOF

    # Step B: Dynamically add the correct number of backend servers
    for (( j=0; j<$num_nodes; j++ )); do
        echo "    server node$((j+1)) ${NODE_IPS[$j]}:8080 check cookie node$((j+1))" >> ./temp_haproxy.cfg
    done

    # Step C: Upload config and restart HAProxy
    scp -i "$PEM_KEY" ./temp_haproxy.cfg ubuntu@$LOAD_BALANCER_IP:~/haproxy.cfg
    ssh -i "$PEM_KEY" ubuntu@$LOAD_BALANCER_IP "sudo mv ~/haproxy.cfg /etc/haproxy/haproxy.cfg && sudo systemctl restart haproxy"
    
    echo "HAProxy restarted with $num_nodes node(s). Waiting 5 seconds..."
    sleep 5

    # ==========================================
    # 3. THE JMETER & MONITORING LOOPS
    # ==========================================
    for class in "${CLASSES[@]}"; do
        for users in "${USER_STEPS[@]}"; do
            echo "TESTING: $num_nodes Nodes | CLASS: $class | USERS: $users"
            
            PREFIX="N${num_nodes}_${class}_U${users}"

            # START MONITORING ON ACTIVE BACKEND NODES ONLY
            for (( k=0; k<$num_nodes; k++ )); do
                CURRENT_NODE="${NODE_IPS[$k]}"
                # Notice we append Node1, Node2, etc., to the CSV filename so they don't overwrite each other
                ssh -i "$PEM_KEY" ubuntu@$CURRENT_NODE "nohup ~/monitor.sh docker_stats_${PREFIX}_Node$((k+1)).csv </dev/null >/dev/null 2>&1 &"
            done

            # Run JMeter against the Load Balancer IP
            "$JMETER_PATH" -n -t class_${class}.jmx \
                -Jhostname=127.0.0.1 \
                -JnumUser=$users \
                -JrampUp=10 \
                -Jduration=$DURATION \
                -Jport=8080 \
                -l ./results/jmeter_results_${PREFIX}.jtl

            # STOP MONITORING AND DOWNLOAD LOGS FROM ACTIVE BACKEND NODES
            for (( k=0; k<$num_nodes; k++ )); do
                CURRENT_NODE="${NODE_IPS[$k]}"
                ssh -i "$PEM_KEY" ubuntu@$CURRENT_NODE "pkill -f monitor.sh"
                scp -i "$PEM_KEY" ubuntu@$CURRENT_NODE:~/docker_stats_${PREFIX}_Node$((k+1)).csv ./results/
                ssh -i "$PEM_KEY" ubuntu@$CURRENT_NODE "rm ~/docker_stats_${PREFIX}_Node$((k+1)).csv"
            done

            echo "Cooling down..."
            sleep 50
        done
    done
done

# Cleanup
rm ./temp_haproxy.cfg

echo "Closing SSH Tunnel..."
pkill -f "ssh -i $PEM_KEY -f -N -L 8080:127.0.0.1:80"
echo "All testing complete!"