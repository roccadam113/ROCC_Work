from langchain_text_splitters import TokenTextSplitter

text_splitter = TokenTextSplitter(
    chunk_size=100,
    chunk_overlap=10,
    model_name="gpt-4",
)

with open("./0206/text.txt", "r", encoding="utf-8") as f:
    text = f.read()


chunks = text_splitter.split_text(text)

print(f"原文長度：{len(text)} tokens")
print(f"分塊數量：{len(chunks)} \n")

for i, chunk in enumerate(chunks):
    print(f"分塊 {i+1} : ")
    print(f"長度： {len(chunk)} tokens")
