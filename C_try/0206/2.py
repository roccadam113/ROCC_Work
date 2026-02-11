from qdrant_client.models import PointStruct
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams
import requests

client = QdrantClient(url="http://localhost:6333")
data = {"texts": ["AI Test"], "normalize": True, "batch_size": 32}

response = requests.post("https://ws-04.wade0426.me/embed", json=data)
if response.status_code == 200:
    result = response.json()
    print(f"CODE：{response.status_code}")
    print(f"回應的内容：{response.text}")
    print(f"維度：{result['dimension']}")
else:
    print(f"錯誤：{response.json()}")


client.upsert(
    collection_name="text_collection",
    points=[
        PointStruct(
            id=1,
            vector=result["embeddings"][0],
            payload={"text": "人工智慧真的很好玩", "metadata": "其他資訊"},
        )
    ],
)
