from langchain_text_splitters import CharacterTextSplitter

text_splitter = CharacterTextSplitter(
    chunk_size=50, chunk_overlap=0, length_function=len
)
with open("./0206/text.txt", "r", encoding="utf-8") as f:
    text = f.read()

chunks = text_splitter.split_text(text)

print(f"總共產生{len(chunks)}個分塊\n")
for i, chunk in enumerate(chunks, 1):
    print(f"===分塊 { i } ===")
    print(f"長度 { len(chunk) } 字符")
    print(f"内容 ：  { chunk.strip() }\n")
