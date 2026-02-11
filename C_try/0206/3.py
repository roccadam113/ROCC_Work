from qdrant_client.models import PointStruct
from qdrant_client import QdrantClient
import requests


def get_embedding(text: list[str]):
    data = {"texts": text, "normalize": True, "batch_size": 32}
    response = requests.post("https://ws-04.wade0426.me/embed", json=data)
    if response.status_code == 200:
        result = response.json()
        return result["embeddings"]
    else:
        raise RuntimeError(response.text)


client = QdrantClient(url="http://localhost:6333")

texts = ["AI 有什麽好處？"]
qdrant_vector = get_embedding(texts)[0]

search_result = client.query_points(
    collection_name="text_collection", query=qdrant_vector, limit=3
)

for p in search_result.points:
    print(f"ID:{p.id}")
    print(f"信心分數:{p.score}")
    print(f"内容:{p.payload['text']}")
    print(f"=========================")
