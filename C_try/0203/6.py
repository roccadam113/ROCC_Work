from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import JsonOutputParser
from langchain_core.output_parsers import StrOutputParser
import json

llm = ChatOpenAI(
    base_url="https://ws-02.wade0426.me/v1",
    api_key="",
    model="Qwen/Qwen3-VL-8B-Instruct",
)

system_prompt = """你是一個資料提取助手。{format_instructions} 需要的欄位：name,phone,product,quantity,address"""

prompt = ChatPromptTemplate.from_messages(
    [("system", system_prompt), ("user", "{text}")]
)

parser = JsonOutputParser()

chain = prompt | llm | parser

user_input = "我是ROCC，電話123-456-789，有3個手機，明天下午到USA"

try:
    result = chain.invoke(
        {"text": user_input, "format_instructions": parser.get_format_instructions()}
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))
except Exception as e:
    print(e)
