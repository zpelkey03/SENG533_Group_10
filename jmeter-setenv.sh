# Copy this file to your JMeter bin directory as setenv.sh to fix UseG1GC on newer JDKs:
#   cp jmeter-setenv.sh /path/to/apache-jmeter-5.6.3/bin/setenv.sh
# Or create setenv.sh in JMETER_HOME/bin with the line below.

# Unlock experimental VM options so -XX:+UseG1GC works on JDK 21+
export GC_ALGO="-XX:+UnlockExperimentalVMOptions -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:G1ReservePercent=20"
