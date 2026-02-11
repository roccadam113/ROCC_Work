from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams
import requests

client = QdrantClient(url="http://localhost:6333")
client.create_collection(
    collection_name="text_collection",
    vectors_config=VectorParams(size=4096, distance=Distance.COSINE),
)

data = {"texts": ["人工智慧很COOL."], "normalize": True, "batch_size": 32}

response = requests.post("https://ws-04.wade0426.me/embed", json=data)

print(f"狀態CODE：{response.status_code}")
print(f"回應的内容：{response.text}")

if requests.status_codes == 200:
    result = response.json()
    print(f"維度：P{result['dimension']}")
    print(f"END_OK")
else:
    print(f"錯誤：{response.json()}")
