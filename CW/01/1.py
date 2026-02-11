from qdrant_client import QdrantClient
from qdrant_client.models import VectorParams, Distance, PointStruct
import requests
import os
import ssl
from requests.adapters import HTTPAdapter
from urllib3.poolmanager import PoolManager


# 限制 TLS 版本範圍 1.2 - 1.3
class TLS1213HttpAdapter(HTTPAdapter):
    def init_poolmanager(self, connections, maxsize, block=False, **pool_kwargs):
        ctx = ssl.create_default_context()
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.maximum_version = ssl.TLSVersion.TLSv1_3
        self.poolmanager = PoolManager(
            num_pools=connections,
            maxsize=maxsize,
            block=block,
            ssl_context=ctx,
            **pool_kwargs,
        )


def make_session_tls1213() -> requests.Session:
    s = requests.Session()
    s.mount("https://", TLS1213HttpAdapter())
    return s


client = QdrantClient(url="http://localhost:6333")
COLLECTION = "cw01_collection"
filename = ["data_01.txt", "data_02.txt", "data_03.txt", "data_04.txt", "data_05.txt"]
texts = []
PATH = "HW/Day5/HW/"
EMBED_SERVER = "https://ws-04.wade0426.me/embed"

for file in filename:
    path = os.path.join(PATH, file)
    with open(path, "r", encoding="utf-8") as f:
        content = f.read().strip()
        texts.append(content)

session = make_session_tls1213()
all_vectors = []
dimension = None
for start in range(0, len(texts), 1):
    chunk_text = texts[start : start + 1]

    data = {"texts": chunk_text, "normalize": True, "batch_size": 32}
    try:
        resp = session.post(EMBED_SERVER, json=data, timeout=60)
        print("Server OK!")
        resp.raise_for_status()
        result = resp.json()
    except Exception as e:
        print(e)
        raise

    if dimension is None:
        dimension = result["dimension"]
    elif dimension != result["dimension"]:
        raise RuntimeError(f"Embedding 維度不同{dimension} vs {result['dimension']}")
    all_vectors.extend(result["embeddings"])

if not client.collection_exists(COLLECTION):
    client.create_collection(
        collection_name=COLLECTION,
        vectors_config=VectorParams(size=dimension, distance=Distance.COSINE),
    )

points = []
for i, (text, vector, fname) in enumerate(zip(texts, all_vectors, filename), start=1):
    points.append(
        PointStruct(id=i, vector=vector, payload={"text": text, "source": fname})
    )

client.upsert(
    collection_name=COLLECTION,
    points=points,
    wait=True,
)

user_input = input("Input: ")
user_data = {"texts": [user_input], "normalize": True, "batch_size": 32}
resp = session.post(EMBED_SERVER, json=user_data, timeout=60)
resp.raise_for_status()
qvec = resp.json()["embeddings"][0]

hit = client.query_points(
    collection_name=COLLECTION, query=qvec, limit=3, with_payload=True
).points

for h in hit:
    print(f"信心分數： {h.score}")
    print(f"來源： {h.payload.get('source')}")
    print(f"内容 : {h.payload.get('text')}")
    print("*" * 50)
