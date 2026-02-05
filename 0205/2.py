from langchain_core.tools import tool
from langchain_core.messages import BaseMessage, HumanMessage, ToolMessage
from langchain_openai import ChatOpenAI
from typing import Annotated, TypedDict, Literal
from langgraph.graph import StateGraph, END, add_messages
from langgraph.prebuilt import ToolNode

llm = ChatOpenAI(
    base_url="https://ws-02.wade0426.me/v1",
    api_key="",
    model="google/gemma-3-27b-it",
    temperature=0,
)


class State(TypedDict):
    og_text: str
    translated_text: str
    critique: str
    attempts: int


def translator(state: State):
    print(f"\n 試圖翻譯 第 {state['attempts']+1} 次\n")
    prompt = f"你是一個專業翻譯官，將中文翻譯成英文，不需要任何解釋: {state['og_text']}"
    if state["critique"]:
        prompt += f'\n\n上一輪翻譯内容審意見是：{state["critique"]}。請根據意見修正翻譯'
    response = llm.invoke([HumanMessage(content=prompt)])
    return {"translated_text": response.content, "attempts": state["attempts"] + 1}


def reflector(state: State):
    print("\n審查中\n")
    print(f"翻譯 : {state['translated_text']}")
    prompt = f"""
            你是一個嚴格的翻譯審查官。
            原文 : {state['og_text']}。
            翻譯 : {state['translated_text']}。

            請檢查翻譯是否準確并且順暢。
            - 如果翻譯的很完美，請只回覆 "PASS"。
            - 如果需要再修改，請給出簡短的具體建議。
            """
    response = llm.invoke([HumanMessage(content=prompt)])
    return {"critique": response.content}


def should_continue(state: State):
    crtitque = state["critique"].strip().upper()

    if "PASS" in crtitque:
        print("\nPASS\n")
        return "end"
    elif state["attempts"] >= 5:
        print("MAX Retry Times")
        return "end"
    else:
        print(f'\n審核未通過 : {state["critique"]}')
        print("重新翻譯……\n")
        return "translator"


workflow = StateGraph(State)
workflow.add_node("translator", translator)
workflow.add_node("reflector", reflector)
workflow.set_entry_point("translator")
workflow.add_edge("translator", "reflector")
workflow.add_conditional_edges(
    "reflector", should_continue, {"translator": "translator", "end": END}
)
app = workflow.compile()
print(app.get_graph().draw_ascii())
while True:
    user_inputs = input("Input： ")
    if user_inputs.lower() in ["q", "exit"]:
        break
    inputs = {"og_text": user_inputs, "attempts": 0, "critique": ""}
    result = app.invoke(inputs)
    print("\n========Result========")
    print(f"原文：{result['og_text']}")
    print(f"翻譯：{result['translated_text']}")
    print(f"翻譯次數：{result['attempts']}")
