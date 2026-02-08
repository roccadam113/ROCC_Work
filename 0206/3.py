from langchain_text_splitters import RecursiveCharacterTextSplitter
import tiktoken

text_splitter = RecursiveCharacterTextSplitter.from_tiktoken_encoder(
    model_name="gpt-4", chunk_size=80, chunk_overlap=10, separators=[""]
)

with open("./0206/text.txt", "r", encoding="utf-8") as f:
    text = f.read()

encoding = tiktoken.encoding_for_model("gpt-4")
chunks = text_splitter.split_text(text)

print(f"原本長度： {len(encoding.encode(text))} tokens")
print(f"分塊數量{len(chunks)}\n")

for i, chunk in enumerate(encoding.encode(chunks)):
    token_count = len(encoding.encode(chunk))
    print(f"===分塊{i}===")
    print(f"長度： {len(token_count)} tokens")
    print(f"内容 ： {chunk} \n")
