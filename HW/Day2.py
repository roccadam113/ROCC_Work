from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import RunnableParallel
import time

inputs = input("Input: ")

llm = ChatOpenAI(
    base_url="https://ws-02.wade0426.me/v1",
    api_key="",
    model="Qwen/Qwen3-VL-8B-Instruct",
    temperature=0,
)

parser = StrOutputParser()
chain_a = (
    ChatPromptTemplate.from_template(
        "你是一個嚴肅的科技專家，寫一個關於{topic}的 20 字貼文"
    )
    | llm
    | parser
)
chain_b = (
    ChatPromptTemplate.from_template("你是一個搞笑藝人，寫一個關於{topic}的 20 字貼文")
    | llm
    | parser
)

combined_chain = RunnableParallel(story_1=chain_a, story_2=chain_b)
print("開始")
for c in combined_chain.stream({"topic": inputs}):
    print(c)

batch_inputs = [
    {"topic": inputs},
    {"topic": inputs + " 的優缺點"},
    {"topic": inputs + " 在生活中的例子"},
]

begin = time.time()
batch_results = combined_chain.batch(batch_inputs)
run_time = time.time() - begin

for i, r in enumerate(batch_results, start=1):
    print(f"\n--- 第 {i} 筆 ---")
    print("科技專家:", r["story_1"])
    print("搞笑藝人:", r["story_2"])
print(f"\nRun Time: {run_time:.2f}s")
