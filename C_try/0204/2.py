from langchain_core.tools import tool
from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
import json

llm = ChatOpenAI(
    base_url="https://ws-02.wade0426.me/v1",
    api_key="",
    model="google/gemma-3-27b-it",
    temperature=0,
)


@tool
def generate_summary(content: str):
    """
    1. 只有當輸入內容屬於「科技」、「程式設計」、「AI」、「軟體工程」或「IT 技術」領域時，才使用此工具。
    2. 如果內容是「閒聊」、「食譜」、「天氣」、「日常日記」等非技術內容，請勿使用此工具。

    功能：將輸入的技術文章歸納出 3 個重點。
    """

    prompt = ChatPromptTemplate.from_messages(
        [
            (
                "system",
                "你是一個資深的科技主編。請將輸入的技術文章內容，精簡地歸納出 3 個關鍵重點 (Key Takeaways)。請用繁體中文輸出。",
            ),
            ("user", "{text}"),
        ]
    )
    chain = prompt | llm | StrOutputParser()
    response = []
    for c in chain.stream({"text": content}):
        print(c.replace("**", ""), end="", flush=True)
        response.append(c)
    print("end")
    return "".join(response)


with_tool = llm.bind_tools([generate_summary])

prompt = ChatPromptTemplate.from_messages([("user", "{input}")])

while True:
    user_input = input("Input: ")
    if user_input.lower() in ["q", "exit"]:
        break
    print("開始")
    chain = prompt | with_tool
    response = chain.invoke({"input": user_input})
    if response.tool_calls:
        print("OK")
        args = response.tool_calls[0]["args"]
        final = generate_summary.invoke(args)
    else:
        print("類別錯誤，直接輸出：")
        print(response.content)
