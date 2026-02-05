from langchain_core.tools import tool
from langchain_core.messages import BaseMessage, HumanMessage, ToolMessage
from langchain_openai import ChatOpenAI
from typing import Annotated, TypedDict, Literal
from langgraph.graph import StateGraph, END, add_messages
from langgraph.prebuilt import ToolNode
from random import randint

llm = ChatOpenAI(
    base_url="https://ws-02.wade0426.me/v1",
    api_key="",
    model="google/gemma-3-27b-it",
    temperature=0,
)


class AgentState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]


@tool
def get_weather(city: str):
    """回傳指定城市的天氣（臺北、臺中、臺南）。"""
    error_num = randint(1, 5)
    if error_num == 3:
        return "Server Error : 502"
    temp = str()
    match (city):
        case "臺北":
            temp = "臺北大雨，18°。"
        case "臺中":
            temp = "臺中晴天，22°。"
        case "臺南":
            temp = "臺南大雨，26°。"
    return temp


tool_node = ToolNode([get_weather])
llm_with_tools = llm.bind_tools([get_weather])


def fallback(state: AgentState):
    messages = state.get("messages")
    if not messages:
        return {"messages": [ToolMessage(content="TOOL異常，沒有内容物")]}
    tool_call_id = messages[-1].tool_calls[0]["id"]
    return {
        "messages": [
            ToolMessage(content="Max Retries Error", tool_call_id=tool_call_id)
        ]
    }


def chat_bot(state: AgentState):
    response = llm_with_tools.invoke(state["messages"])
    return {"messages": [response]}


def router(state: AgentState):
    messages = state.get("messages")
    if not messages:
        return "end"
    if not messages[-1].tool_calls:
        return "end"

    retry_count = 0
    for m in reversed(messages[:-1]):
        if isinstance(m, ToolMessage):
            if "502" in m.content:
                retry_count += 1
            else:
                break
        elif isinstance(m, HumanMessage):
            break
    print(f"Debug:Retry Count : {retry_count}")
    if retry_count >= 1:
        return "fallback"
    return "tools"


workflow = StateGraph(AgentState)
workflow.add_node("tools", tool_node)
workflow.add_node("agent", chat_bot)
workflow.add_node("fallback", fallback)
workflow.set_entry_point("agent")
workflow.add_conditional_edges(
    "agent",
    router,
    {"tools": "tools", "fallback": "fallback", "end": END},
)

workflow.add_edge("tools", "agent")
workflow.add_edge("fallback", "agent")

app = workflow.compile()
print(app.get_graph().draw_ascii())


while True:
    user_inputs = input("Input: ")
    if user_inputs.lower() in ["q", "exit"]:
        break

    for e in app.stream({"messages": [HumanMessage(content=user_inputs)]}):
        for k, v in e.items():
            match (k):
                case "agent":
                    m = v.get("messages")[-1]
                    if m.tool_calls:
                        print("Tool Call")
                    else:
                        print(m.content)
                case "tools":
                    print("System Error...Retrying")
                case "fallback":
                    print("Majo Error FULL STOP")
