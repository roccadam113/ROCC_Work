from langchain_text_splitters import CharacterTextSplitter
from langchain_text_splitters import TokenTextSplitter
from qdrant_client import QdrantClient
from qdrant_client.models import VectorParams, Distance, PointStruct
import requests
import ssl
from requests.adapters import HTTPAdapter
from urllib3.poolmanager import PoolManager
import uuid
import csv
import os
import pandas as pd
import re

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


SESSION = make_session_tls1213()
CLIENT = QdrantClient(url=QDRANT_URL)


def embedding_text(texts: list[str]):
    data = {"texts": texts, "normalize": True, "batch_size": 32}
    try:
        resp = SESSION.post(EMBED_SERVER, json=data, timeout=60)
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
    collection: str,
    chunks: list[str],
    source: str,
    batch: int = 5,
):
    first = chunks[:batch]
    d, vecs = embedding_text(first)
    dimension = d

    if CLIENT.collection_exists(collection):
        CLIENT.delete_collection(collection)

    CLIENT.create_collection(
        collection_name=collection,
        vectors_config=VectorParams(size=dimension, distance=Distance.COSINE),
    )

    points = []
    for idx, (t, v) in enumerate(zip(first, vecs), start=1):
        points.append(
            PointStruct(
                id=str(uuid.uuid4()),
                vector=v,
                payload={"text": t, "source": source, "chunk_id": idx},
            )
        )
    CLIENT.upsert(collection_name=collection, points=points, wait=True)

    chunk_id = len(first) + 1
    for i in range(batch, len(chunks), batch):
        batch_chunks = chunks[i : i + batch]
        d, vecs = embedding_text(batch_chunks)
        if d != dimension:
            raise RuntimeError(f"Embedding 維度不同 {dimension} vs {d}")

        points = []
        for t, v in zip(batch_chunks, vecs):
            points.append(
                PointStruct(
                    id=str(uuid.uuid4()),
                    vector=v,
                    payload={"text": t, "source": source, "chunk_id": chunk_id},
                )
            )
            chunk_id += 1

        CLIENT.upsert(collection_name=collection, points=points, wait=True)

    print(f"完成：{len(chunks)} chunks -> {collection}")


def search_vdb(
    query: str,
    collection: str,
    limit: int = 3,
):
    d, q = embedding_text([query])
    result = CLIENT.query_points(
        collection_name=collection,
        query=q[0],
        limit=limit,
        with_payload=True,
    )
    hits = getattr(result, "points", result)

    for h in hits:
        payload = h.payload or {}
        print(f"分數：{h.score}")
        print(f"來源：{payload.get('source')}")
        print(f"chunk_id：{payload.get('chunk_id')}")
        print(f"內容：{payload.get('text')}")
        print("-" * 50)


def from_text():
    with open("./CW/02/text.txt", "r", encoding="utf-8") as f:
        text = f.read()

    fixed_chunks = fix_splitter(text)
    sliding_chunks = sliding_splitter(text)

    upsert_chunks_qdrant("cw02_fixed", fixed_chunks, source="text.txt")
    upsert_chunks_qdrant("cw02_sliding", sliding_chunks, source="text.txt")

    q = input("Input: ")
    print("\n=== fixed 結果 ===")
    search_vdb(q, "cw02_fixed")

    print("\n=== sliding 結果 ===")
    search_vdb(q, "cw02_sliding")


def markdown_to_chunks(max_chars: int = 500):
    with open("./CW/02/table/table_txt.md", "r", encoding="utf-8") as f:
        content = f.read()

    lines = content.strip().split("\n")
    chunks = []
    buf = []

    header_re = re.compile(r"^\s{0,3}#{1,6}\s+")
    table_line_re = re.compile(r"^\|.*\|$")

    table_buf = []
    in_table = False

    def flush_buf():
        nonlocal buf
        if buf:
            chunks.append("\n".join(buf).strip())
            buf = []

    def flush_table():
        nonlocal table_buf, in_table
        if table_buf:
            chunks.append("\n".join(table_buf).strip())
            table_buf = []
        in_table = False

    for line in lines:
        is_table_line = bool(table_line_re.match(line))

        if is_table_line:
            if buf:
                flush_buf()
            in_table = True
            table_buf.append(line.rstrip())
            continue

        if in_table and not is_table_line:
            flush_table()

        if header_re.match(line) and buf:
            flush_buf()
            buf.append(line.rstrip())
        else:
            buf.append(line.rstrip())

    flush_buf()
    flush_table()

    final_chunks = []
    for c in chunks:
        if len(c) <= max_chars:
            final_chunks.append(c)
        else:
            for i in range(0, len(c), max_chars):
                final_chunks.append(c[i : i + max_chars].strip())

    return [c for c in final_chunks if c]


def from_table():
    upsert_chunks_qdrant("table_txt_md", markdown_to_chunks(), source="table_txt.md")
    q = input("Input: ")
    print("\n=== Table 結果 ===")
    search_vdb(q, "table_txt_md")


if __name__ == "__main__":
    # from_text()
    from_table()
