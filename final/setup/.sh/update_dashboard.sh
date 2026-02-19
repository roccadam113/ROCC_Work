export FOLDER_UID='efdpnbasqwydcf'
export DS_UID='PBFA97CFB590B2093'

curl -sS -u "admin:rocc113" \
  -H 'Content-Type: application/json' \
  -d "{
    \"folderUid\": \"${FOLDER_UID}\",
    \"overwrite\": true,
    \"dashboard\": {
      \"uid\": \"cfdpnbb7nt4owc\",
      \"title\": \"tenant-rocc-full1-overview\",
      \"timezone\": \"browser\",
      \"schemaVersion\": 39,
      \"version\": 1,
      \"refresh\": \"10s\",
      \"tags\": [\"tenant\", \"gpu\", \"fake-dcgm\"],
      \"templating\": {
        \"list\": [
          {
            \"type\": \"query\",
            \"name\": \"tenant\",
            \"label\": \"Tenant\",
            \"datasource\": {\"type\": \"prometheus\", \"uid\": \"${DS_UID}\"},
            \"query\": {\"query\": \"label_values(fake_gpu_utilization_percent, tenant)\", \"refId\": \"PromQ\"},
            \"includeAll\": true,
            \"allValue\": \".*\",
            \"multi\": true,
            \"refresh\": 1,
            \"current\": {\"selected\": true, \"text\": \"All\", \"value\": [\".*\"]}
          },
          {
            \"type\": \"query\",
            \"name\": \"api_key\",
            \"label\": \"API Key\",
            \"datasource\": {\"type\": \"prometheus\", \"uid\": \"${DS_UID}\"},
            \"query\": {\"query\": \"label_values(fake_gpu_utilization_percent{tenant=~\\\"\$tenant\\\"}, api_key)\", \"refId\": \"PromQ\"},
            \"includeAll\": true,
            \"allValue\": \".*\",
            \"multi\": true,
            \"refresh\": 1,
            \"current\": {\"selected\": true, \"text\": \"All\", \"value\": [\".*\"]}
          }
        ]
      },
      \"panels\": [
        {
          \"type\": \"timeseries\",
          \"title\": \"GPU Utilization (%)\",
          \"datasource\": {\"type\": \"prometheus\", \"uid\": \"${DS_UID}\"},
          \"gridPos\": {\"h\": 9, \"w\": 24, \"x\": 0, \"y\": 0},
          \"targets\": [
            {
              \"refId\": \"A\",
              \"expr\": \"avg by (tenant, api_key) (fake_gpu_utilization_percent{tenant=~\\\"\$tenant\\\", api_key=~\\\"\$api_key\\\"})\",
              \"legendFormat\": \"{{tenant}} / {{api_key}}\"
            }
          ]
        },
        {
          \"type\": \"timeseries\",
          \"title\": \"GPU Memory Used (MB)\",
          \"datasource\": {\"type\": \"prometheus\", \"uid\": \"${DS_UID}\"},
          \"gridPos\": {\"h\": 9, \"w\": 24, \"x\": 0, \"y\": 9},
          \"targets\": [
            {
              \"refId\": \"A\",
              \"expr\": \"avg by (tenant, api_key) (fake_gpu_memory_used_megabytes{tenant=~\\\"\$tenant\\\", api_key=~\\\"\$api_key\\\"})\",
              \"legendFormat\": \"{{tenant}} / {{api_key}}\"
            }
          ]
        },
        {
          \"type\": \"timeseries\",
          \"title\": \"GPU Power (W)\",
          \"datasource\": {\"type\": \"prometheus\", \"uid\": \"${DS_UID}\"},
          \"gridPos\": {\"h\": 9, \"w\": 24, \"x\": 0, \"y\": 18},
          \"targets\": [
            {
              \"refId\": \"A\",
              \"expr\": \"avg by (tenant, api_key) (fake_gpu_power_watts{tenant=~\\\"\$tenant\\\", api_key=~\\\"\$api_key\\\"})\",
              \"legendFormat\": \"{{tenant}} / {{api_key}}\"
            }
          ]
        }
      ]
    }
  }" \
  http://127.0.0.1:13000/api/dashboards/db | sed -n '1,220p'
