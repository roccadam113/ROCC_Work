from langchain_text_splitters import CharacterTextSplitter
from langchain_text_splitters import TokenTextSplitter
from qdrant_client import QdrantClient
from qdrant_client.models import VectorParams, Distance, PointStruct
import requests
import ssl
from requests.adapters import HTTPAdapter
from urllib3.poolmanager import PoolManager
import uuid

COLLECTION = "cw02_collention"
EMBED_SERVER = "https://ws-04.wade0426.me/embed"
QDRANT_URL = "http://localhost:6333"


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


def embedding_text(texts: list[str], session: requests.Session):
    data = {"texts": texts, "normalize": True, "batch_size": 32}
    try:
        resp = session.post(EMBED_SERVER, json=data, timeout=60)
        print(f"HTTP : {resp.status_code}")
        resp.raise_for_status()
        result = resp.json()
        return result["dimension"], result["embeddings"]
    except Exception as e:
        print(f"Embedding 失敗了{e}")
        raise


def fix_splitter(text: str):
    text_splitter = CharacterTextSplitter(
        chunk_size=50, chunk_overlap=0, separator="", length_function=len
    )
    chunks = text_splitter.split_text(text)

    print(f"產生了{len(chunks)}")

    # for i, chunk in enumerate(chunks, 1):
    #     print(f"==== {i} ====== ")
    #     print(f"長度:{len(chunk)}")
    #     print(f"内容:{chunk.strip()}\n")
    return chunks


def sliding_splitter(text: str):
    text_splitter = TokenTextSplitter(
        chunk_size=100, chunk_overlap=10, model_name="gpt-4"
    )
    chunks = text_splitter.split_text(text)
    print(f"OG文件長度：{len(text)}")
    print(f"分塊數量：{len(chunks)}\n")
    return chunks


def upsert_chunks_qdrant(
    chunks: list[str],
    session: requests.Session,
    client: QdrantClient,
    source: str = "text.txt",
):
    BATCH = 5
    all_vectors = []
    dimension = None
    for i in range(0, len(chunks), BATCH):
        batch_chunks = chunks[i : i + BATCH]
        d, vecs = embedding_text(batch_chunks, session)
        if dimension is None:
            dimension = d
        elif dimension != d:
            raise RuntimeError(f"Embedding 維度不同{dimension} vs {d}")
        all_vectors.extend(vecs)

    if not client.collection_exists(COLLECTION):
        client.create_collection(
            collection_name=COLLECTION,
            vectors_config=VectorParams(size=dimension, distance=Distance.COSINE),
        )

    points = []

    for t, v in zip(chunks, all_vectors):
        points.append(
            PointStruct(
                id=str(uuid.uuid4()), vector=v, payload={"text": t, "source": source}
            )
        )

    client.upsert(collection_name=COLLECTION, points=points, wait=True)
    print(f"節點完成：{len(points)}\npoints into->{COLLECTION}\n")


def search_vdb(
    query: str,
    collection: str,
    session: requests.Session,
    client: QdrantClient,
    limit: int = 3,
):
    d, q = embedding_text([query], session)
    result = client.query_points(collection_name=collection, query=q[0], limit=limit)
    hits = getattr(result, "points", result)
    for h in hits:
        print(f"信心分數： {h.score}")
        print(f"來源： {h.payload.get('source')}")
        print(f"内容 : {h.payload.get('text')}")
        print("*" * 50)


if __name__ == "__main__":
    with open("./CW/02/text.txt", "r", encoding="utf-8") as f:
        text = f.read()

    # fix_splitter(text)
    chunks = sliding_splitter(text)
    session = make_session_tls1213()
    client = QdrantClient(url=QDRANT_URL)
    upsert_chunks_qdrant(chunks, session, client)

    user_input = input("Input : ")
    search_vdb(user_input, COLLECTION, session, client, limit=3)
