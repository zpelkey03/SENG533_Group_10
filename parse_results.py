import os
import glob
import argparse
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns

def parse_jtl(file_path):
    """Extracts Throughput and Latency from a JMeter JTL file."""
    try:
        df = pd.read_csv(file_path)
        total_requests = len(df)
        if total_requests == 0:
            return None

        errors = len(df[df['success'] == False])
        error_rate = (errors / total_requests) * 100
        avg_latency = df['elapsed'].mean()

        min_time = df['timeStamp'].min()
        max_time = df['timeStamp'].max()
        duration_seconds = (max_time - min_time) / 1000.0
        throughput = total_requests / duration_seconds if duration_seconds > 0 else 0

        return {
            "Throughput_RPS": round(throughput, 2),
            "Avg_Latency_ms": round(avg_latency, 2),
            "Error_Rate_%": round(error_rate, 2)
        }
    except Exception as e:
        print(f"Error parsing JTL {file_path}: {e}")
        return None

def parse_docker_stats(file_path):
    """Extracts average CPU utilization per container from the monitor CSV."""
    try:
        df = pd.read_csv(file_path)
        if df.empty:
            return {}
        
        # Clean the CPU percentage string (e.g., "15.4%" -> 15.4)
        df['CPU_Perc'] = df['CPU_Perc'].astype(str).str.replace('%', '').astype(float)
        
        # Group by container name and get the mean CPU usage over the run
        cpu_means = df.groupby('Container')['CPU_Perc'].mean().to_dict()
        
        # Format keys to be column-friendly
        return {f"{k}_CPU_%": round(v, 2) for k, v in cpu_means.items()}
    except Exception as e:
        print(f"Error parsing Docker CSV {file_path}: {e}")
        return {}

def generate_network_visualizations(df, output_dir):
    """Generates PNG graphs for Throughput and Latency."""
    sns.set_theme(style="whitegrid")
    classes = df['Workload_Class'].unique()

    for workload in classes:
        class_data = df[df['Workload_Class'] == workload]

        # Throughput Graph
        plt.figure(figsize=(10, 6))
        sns.lineplot(data=class_data, x='Concurrent_Users', y='Throughput_RPS', hue='Hardware_Config', marker='o', linewidth=2)
        plt.title(f"Throughput Saturation - {workload.capitalize()} Class", fontsize=14, pad=15)
        plt.xlabel("Concurrent Users", fontsize=12)
        plt.ylabel("Throughput (Requests / Second)", fontsize=12)
        plt.legend(title="Hardware Tier", bbox_to_anchor=(1.05, 1), loc='upper left')
        plt.tight_layout()
        plt.savefig(os.path.join(output_dir, f"{workload}_throughput.png"), dpi=300)
        plt.close()

        # Latency Graph
        plt.figure(figsize=(10, 6))
        sns.lineplot(data=class_data, x='Concurrent_Users', y='Avg_Latency_ms', hue='Hardware_Config', marker='s', linewidth=2)
        plt.title(f"Latency Spikes - {workload.capitalize()} Class", fontsize=14, pad=15)
        plt.xlabel("Concurrent Users", fontsize=12)
        plt.ylabel("Average Latency (ms)", fontsize=12)
        plt.legend(title="Hardware Tier", bbox_to_anchor=(1.05, 1), loc='upper left')
        plt.tight_layout()
        plt.savefig(os.path.join(output_dir, f"{workload}_latency.png"), dpi=300)
        plt.close()

def generate_cpu_visualizations(df, output_dir):
    """Generates CPU utilization graphs for the Docker containers."""
    sns.set_theme(style="whitegrid")
    
    # Identify all columns that represent a container's CPU usage
    cpu_columns = [col for col in df.columns if col.endswith('_CPU_%')]
    if not cpu_columns:
        return

    hardware_runs = df['Hardware_Config'].unique()
    classes = df['Workload_Class'].unique()

    for run in hardware_runs:
        for workload in classes:
            # Filter data for this specific run and workload
            subset = df[(df['Hardware_Config'] == run) & (df['Workload_Class'] == workload)]
            if subset.empty:
                continue

            plt.figure(figsize=(10, 6))
            
            # Plot a line for each microservice container
            for col in cpu_columns:
                container_name = col.replace('_CPU_%', '')
                plt.plot(subset['Concurrent_Users'], subset[col], marker='o', linewidth=2, label=container_name)

            plt.title(f"Container CPU Load - {run.capitalize()} ({workload.capitalize()})", fontsize=14, pad=15)
            plt.xlabel("Concurrent Users", fontsize=12)
            plt.ylabel("Average CPU Utilization (%)", fontsize=12)
            
            # Y-axis logic: If they gave it 4 CPUs, it might read up to 400%. 
            # We let matplotlib auto-scale, but ensure it starts at 0.
            plt.ylim(bottom=0) 
            
            plt.legend(title="Microservice", bbox_to_anchor=(1.05, 1), loc='upper left')
            plt.tight_layout()
            
            # Save the file (e.g., run1_browsing_cpu_load.png)
            safe_filename = f"{run}_{workload}_cpu_load.png"
            plt.savefig(os.path.join(output_dir, safe_filename), dpi=300)
            plt.close()

def main():
    parser = argparse.ArgumentParser(description="Parse SENG533 JMeter and Docker results.")
    parser.add_argument("results_dir", help="Path to the directory containing JTL and CSV files")
    args = parser.parse_args()

    results_dir = args.results_dir
    jtl_files = glob.glob(os.path.join(results_dir, "jmeter_results_*.jtl"))
    
    if not jtl_files:
        print(f"No JTL files found in {results_dir}.")
        return

    print(f"Found {len(jtl_files)} test runs. Parsing data...")
    master_data = []

    for jtl_path in jtl_files:
        filename = os.path.basename(jtl_path)
        try:
            parts = filename.replace("jmeter_results_", "").replace(".jtl", "").split("_")
            run_config, test_class, users_str = parts[0], parts[1], parts[2]
            users = int(users_str.replace("U", ""))
            
            docker_csv_name = f"docker_stats_{run_config}_{test_class}_U{users}.csv"
            docker_path = os.path.join(results_dir, docker_csv_name)

            jtl_metrics = parse_jtl(jtl_path)
            docker_metrics = parse_docker_stats(docker_path) if os.path.exists(docker_path) else {}

            if jtl_metrics:
                row = {
                    "Hardware_Config": run_config,
                    "Workload_Class": test_class,
                    "Concurrent_Users": users,
                    **jtl_metrics,
                    **docker_metrics
                }
                master_data.append(row)
                
        except Exception as e:
            print(f"Skipping {filename} due to parsing error: {e}")

    if not master_data:
        print("Failed to compile any data.")
        return

    df = pd.DataFrame(master_data)
    df = df.sort_values(by=["Workload_Class", "Hardware_Config", "Concurrent_Users"])

    csv_output = os.path.join(results_dir, "Master_Metrics.csv")
    df.to_csv(csv_output, index=False)
    print(f"\n✅ Master data saved to: {csv_output}")

    print("🎨 Generating Network PNGs (Throughput & Latency)...")
    generate_network_visualizations(df, results_dir)
    
    print("🎨 Generating Container Resource PNGs (CPU Load)...")
    generate_cpu_visualizations(df, results_dir)
    
    print(f"✅ All visualizations saved to: {results_dir}")

if __name__ == "__main__":
    main()