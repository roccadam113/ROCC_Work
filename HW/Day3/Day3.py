from langchain_core.tools import tool
from langchain_core.messages import BaseMessage
from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from typing import Annotated, TypedDict
from langgraph.graph import StateGraph, END, add_messages
from HW.tools.HW_asr import asr
from os import path
import re

WAV_PATH = "HW\Podcast_EP14.wav"
OUT_DIR = "./out"


llm = ChatOpenAI(
    base_url="https://ws-02.wade0426.me/v1",
    api_key="",
    model="google/gemma-3-27b-it",
    temperature=0,
    timeout=120,
    max_retries=2,
)


class AgentState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]
    wav_path: str
    transcript: str
    minutes: str
    summary: str
    srt: str
    final: str
    written: bool


def Asr(state: AgentState):
    data = asr(state["wav_path"])
    return {"transcript": data["transcript"], "srt": data["srt"]}


def Minutes_taker(state: AgentState):
    print("\n================開始整理逐字稿================\n")
    text = state["srt"]
    if not text.strip():
        print("沒有SRT")
        return {"minutes": ""}
    try:
        prompt = ChatPromptTemplate(
            [
                (
                    "system",
                    """
                    你是一個「SRT 格式重排」工具，只允許做格式整理，不允許改動任何時間碼或文字內容。

                    輸入是標準 SRT，包含：
                    (1) 序號
                    (2) 時間碼行：HH:MM:SS,mmm --> HH:MM:SS,mmm
                    (3) 1~多行字幕文字

                    請輸出為「每個時間段一行」，格式必須完全一致：
                    HH:MM:SS,mmm --> HH:MM:SS,mmm␠␠字幕文字

                    規則：
                    - 時間碼必須與輸入完全一致（包含逗號、數字、空白、箭頭），不得改動、不得四捨五入、不得補零、不得替換逗號為小數點
                    - 同一時間段的多行字幕要合併成同一行，行內用單一空白連接
                    - 去除字幕文字中多餘空白（連續空白縮成一個空白），但不要改字
                    - 移除序號與空白行
                    - 不要輸出任何標題、說明、Markdown、清單符號，只輸出結果
                    """.strip(),
                ),
                ("user", "{text}"),
            ]
        )

        chain = prompt | llm | StrOutputParser()
        result = chain.invoke({"text": text})
        print("\n================整理完成================\n")
        return {"minutes": result}
    except Exception as e:
        print(f"逐字稿 LLM 整理異常，改用直接修整，錯誤訊息：{e}\n")
        out = []
        buffer = []
        time_now = None
        time_re = re.compile(
            r"^(\d{2}:\d{2}:\d{2}[,\.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,\.]\d{3})$"
        )

        for line in state["srt"].splitlines():
            line = line.strip()
            if not line or line.isdigit():
                continue
            m = time_re.match(line)
            if m:
                if time_now and buffer:
                    out.append(f"{time_now}  {' '.join(buffer)}")
                time_now = f"{m.group(1)} --> {m.group(2)}"
                buffer = []
            else:
                if time_now:
                    buffer.append(line)

        if time_now and buffer:
            out.append(f"{time_now}  {' '.join(buffer)}")
        print("================整理完成================\n")
        return {"minutes": "\n".join(out)}


def Summarizer(state: AgentState):
    """
    會議記錄專業嚴謹摘要工具
    會將文字檔全部内容做一個專業摘要。
    """
    print("================開始生成摘要================\n")
    content = state["transcript"]
    prompt = ChatPromptTemplate(
        [
            (
                "system",
                "你是一個資深專業的摘要撰寫者。請從逐字稿整理：重點、決策、代辦事項。用繁體中文輸出。",
            ),
            ("user", "{text}"),
        ]
    )
    chain = prompt | llm | StrOutputParser()
    response = chain.invoke({"text": content})
    print("================生成摘要完成================\n")
    return {"summary": response.replace("**", "")}


def writer(state: AgentState):
    print("\n================逐字稿================\n")
    print(state.get("minutes"))
    print("\n================摘要================\n")
    print(state.get("summary"))
    print("\n================END================\n")
    return {"final": f"{state['minutes']}\n\n{state['summary']}"}


def should_continue(state: AgentState):
    if state.get("minutes") and state.get("summary"):
        return "writer"
    return END


workflow = StateGraph(AgentState)
workflow.add_node("asr", Asr)
workflow.add_node("minutes_taker", Minutes_taker)
workflow.add_node("summarizer", Summarizer)
workflow.add_node("writer", writer)

workflow.set_entry_point("asr")

workflow.add_edge("asr", "minutes_taker")
workflow.add_edge("asr", "summarizer")
workflow.add_edge(["minutes_taker", "summarizer"], "writer")

workflow.add_edge("writer", END)

app = workflow.compile()
print(app.get_graph().draw_ascii())

app.invoke({"wav_path": WAV_PATH})
