from langchain_core.tools import tool
from langchain_core.messages import BaseMessage, HumanMessage
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


@tool
def get_weather(city: str):
    """回傳指定城市的天氣（臺北、臺中、臺南）。"""
    temp = str()
    match (city):
        case "臺北":
            temp = "臺北大雨，18°。"
        case "臺中":
            temp = "臺中晴天，22°。"
        case "臺南":
            temp = "臺南大雨，26°。"
    return temp


with_tool = llm.bind_tools([get_weather])


class AgentState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]


def chatbot_node(state: AgentState):
    response = with_tool.invoke(state["messages"])
    return {"messages": [response]}


tool_node = ToolNode([get_weather])


def router(state: AgentState) -> Literal["tools", "end"]:
    """
    路由：決定下一步驟執行工具或者結束
    """
    last_messages = state["messages"][-1]

    if last_messages.tool_calls:
        return "tools"
    else:
        return "end"


workflow = StateGraph(AgentState)
workflow.add_node("agent", chatbot_node)
workflow.add_node("tools", tool_node)
workflow.set_entry_point("agent")
workflow.add_conditional_edges("agent", router, {"tools": "tools", "end": END})
workflow.add_edge("tools", "agent")

app = workflow.compile()
print(app.get_graph().draw_ascii())

while True:
    try:
        user_input = "臺中"
        if user_input.lower() in ["q", "exit"]:
            break
        for e in app.stream({"messages": [HumanMessage(content=user_input)]}):
            for k, v in e.items():
                print(f"Node:{k}")
                print(v["messages"][-1].content or v["messages"][-1].tool_calls)
    except Exception as e:
        print(e)
