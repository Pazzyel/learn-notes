# Chain

## 体验LangChain链

将组件串联，上一个组件的输出作为下一个组件的输入」是 LangChain 链（尤其是 | 管道链）的核心工作原理，这也是链式调用的核心价值：实现数据的自动化流转与组件的协同工作

Runnable子类对象才能入链（以及Callable、Mapping接口子类对象也可加入）

```python
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langchain_community.chat_models.tongyi import ChatTongyi

chat_prompt_template = ChatPromptTemplate.from_messages(
    [
        ("system", "你是一个边塞诗人，可以作诗。"),
        # 占位符，表示这里会注入一个消息列表，消息列表的格式是一个元组列表，
        # 每个元组包含两个元素，第一个元素是消息类型（system、human、ai），第二个元素是消息内容
        MessagesPlaceholder("history"), 
        ("human", "请再来一首唐诗"),
    ]
)

history_data = [
    ("human", "你来写一个唐诗"),
    ("ai", "床前明月光，疑是地上霜，举头望明月，低头思故乡"),
    ("human", "好诗再来一个"),
    ("ai", "锄禾日当午，汗滴禾下锄，谁知盘中餐，粒粒皆辛苦"),
]

# StringPromptValue    to_string()
prompt_text = chat_prompt_template.invoke({"history": history_data}).to_string()

model = ChatTongyi(model="qwen3-max")

res = model.invoke(prompt_text)

print(res.content, type(res))
```

存在什么问题？我们需要先手动构建好prompt文本，再调用模型。
如果你接触过数据流编程（比如Java Stream API、Python的管道操作符|等），
可能会想到能不能直接把few_shot_template和模型组合成一个chain，
这样我们在调用chain的时候直接传入变量，
chain内部会自动帮我们构建好prompt文本并调用模型呢？
答案是可以的，我们可以使用管道操作符|来把few_shot_template和模型组合成一个chain

```python
# StringPromptValue    to_string()
model = ChatTongyi(model="qwen3-max")

chain: RunnableSerializable = chat_prompt_template | model

res = chain.invoke(input={"history": history_data})
print(res.content, type(res))

for chunk in chain.stream(input={"history": history_data}):
    print(chunk.content, end="", flush=True)
```

通过上面的例子，我们可以看到，LangChain的PromptTemplate和模型是可以组合成一个chain的，
这样我们在调用chain的时候直接传入变量，chain内部会自动帮我们
构建好prompt文本并调用模型，非常方便快捷

- 可以通过 “|” 符号来让各个组件形成链
- 成链的各个组件，需是Runnable接口的子类
- 形成的链是RunnableSerializable对象（Runnabl接口子类）
- 可通过链调用invoke或stream触发整个链条的执行

你可能会疑惑 “|” 不是Python的位运算符吗？怎么能用来组合PromptTemplate和模型呢？
如果你接触过C++，你可能会知道，C++的运算符是可以重载的，Python也是一样的，
其实在LangChain中，开发者重载了Python的管道操作符|，使得我们可以用它来组合不同的组件

## 链式调用的类型

LangChain 中的绝大多数核心组件都继承了 Runnable 抽象基类

Runnable -> RunnableSerializable -> RunnableSequence

chain变量是RunnableSequence（RunnableSerializable子类）类型。
而得到这个类型的原因就是Runnable基类内部对__or__魔术方法的改写。

`|`在LangChain中被重载了，Runnable类中的__or__方法，这个方法接受一个Runnable对象作为参数，会返回一个新的RunnableSequence对象

同时，在后面继续使用|添加新的组件，依旧会得到RunnableSequence，这就是链的基础架构。

通常情况，链的组建应该是

初始输入 -> 提示词模板 -> 模型 -> 数据处理 -> 提示词模板 -> 模型 -> 解析器 -> 结果

我们在这条链上调用invoke或者stream方法，链条上的组件就会按照顺序被调用对应的invoke或者stream方法，数据会在组件之间自动流转

## 提示词模板

BasePromptTemplate: dict -> PromptValue

有三种常用的PromptTemplate：

- PromptTemplate：输入输出都是字符串
- ChatPromptTemplate：输入输出都是消息列表（MessageValue）
- FewShotPromptTemplate：输入输出都是字符串，且支持few-shot的功能

## 模型

有两种常用的模型：

- LLM: PromptValue | str | Sequence[MessageLikeRepresentation] -> str
- ChatModel：PromptValue | str | Sequence[MessageLikeRepresentation] -> AIMessage

还有一种向量模型，它没有invoke方法

## 数据处理

### StrOutputParser

StrOutputParser: AIMessage -> str

```python
parser = StrOutputParser()
```

`StrOutputParser`是LangChain内置的简单字符串解析器，可以将`AIMessage`解析为简单的字符串，符合了模型`invoke()`方法要求。此外，`StrOutputParser`也是一个Runnable对象，可以直接加入链中使用。也就是说，我们在AIMessage输出和下一个模型输入之间加入一个`StrOutputParser`，就可以实现多重链的构建

### JsonOutputParser

JsonOutputParser: AIMessage -> dict

```python
json_parser = JsonOutputParser()
```

`JsonOutputParser`是LangChain内置的一个JSON解析器，可以将`AIMessage`解析为Python字典（dict）。它的工作原理是从AIMessage的内容中提取出JSON字符串，并将其转换为Python字典对象。这样，我们就可以在链中直接使用这个字典对象进行后续的处理，比如传递给下一个模型或者进行数据分析等操作

### RunableLambda 自定义链上组件

```python
str_parser = StrOutputParser()
my_component = RunnableLambda(lambda ai_msg: {"name": ai_msg.content})
```

`my_component`是一个自定义的链上组件，它使用了`RunnableLambda`来创建一个可运行的组件。这个组件接受一个`AIMessage`对象作为输入，并返回一个包含名字的字典

```python
chain = first_prompt | model | (lambda ai_msg: {"name": ai_msg.content}) | second_prompt | model | str_parser
```

也可以直接把lambda函数放在链中，作为一个组件来使用，这样就不需要单独定义一个`RunnableLambda`对象了，链条会自动识别这个lambda函数，并将其作为一个组件来执行

本质是`|`也可以接受Callable对象（比如lambda函数），其实是将其转换为一个RunnableLambda对象来执行

## 链式调用的历史记录

### 内存记忆

```python
model = ChatTongyi(model="qwen3-max")

# 使用历史消息模板
prompt = ChatPromptTemplate.from_messages(
    [
        ("system", "你需要根据会话历史回应用户问题。对话历史："),
        MessagesPlaceholder("chat_history"),
        ("human", "请回答如下问题：{input}")
    ]
)

str_parser = StrOutputParser()

# 嵌入promopt -> 模型调用 -> 结果解析
base_chain = prompt | model | str_parser


store = {}      
# key就是session，value就是InMemoryChatMessageHistory类对象
# 实现通过会话id获取InMemoryChatMessageHistory类对象
def get_history(session_id):
    if session_id not in store:
        store[session_id] = InMemoryChatMessageHistory()

    return store[session_id]

# 创建一个新的链，对原有链增强功能：自动附加历史消息
conversation_chain = RunnableWithMessageHistory(
    base_chain,     # 被增强的原有chain
    get_history,    # 通过会话id获取InMemoryChatMessageHistory类对象
    input_messages_key="input",             # 表示用户输入在模板中的占位符
    history_messages_key="chat_history"     # 表示用户输入在模板中的占位符
)

if __name__ == '__main__':
    # 固定格式，添加LangChain的配置，为当前程序配置所属的session_id
    session_config = {
        "configurable": {
            "session_id": "user_001"
        }
    }

    res = conversation_chain.invoke({"input": "小明有2个猫"}, session_config)
    print("第1次执行：", res)
    
    res = conversation_chain.invoke({"input": "小刚有1只狗"}, session_config)
    print("第2次执行：", res)

    res = conversation_chain.invoke({"input": "总共有几个宠物"}, session_config)
    print("第3次执行：", res)
```

- 基于RunnableWithMessageHistory在原有链的基础上创建带有历史记录功能的新链（新Runnable实例）
- 基于InMemoryChatMessageHistory为历史记录提供内存存储（临时用）

虽然你传入了只是{"input": "小明有2个猫"}，但是在链条内部，会自动组装上历史记录，如下

```json
{
    "input": "小刚有1只狗", 
    "chat_history": []
}
```

当没有历史记录时，chat_history就是一个空列表，当有历史记录时，chat_history就会包含之前的对话内容，比如

```json
{
    "input": "总共有几个宠物", 
    "chat_history": [
        {"type": "human", "content": "小明有2个猫"},
        {"type": "ai", "content": "好的，我知道了，小明有2个猫"},
        {"type": "human", "content": "小刚有1只狗"},
        {"type": "ai", "content": "好的，我知道了，小刚有1只狗"}
    ]
}

其中`"chat_history"`的名字是在`history_messages_key="chat_history" `指定的

RunnableWithMessageHistory是一个链式组件，可以将一个普通的链增强为具有消息历史功能的链。它接受一个原有的链（base_chain）和一个获取历史消息的函数（get_history），以及两个关键字参数，分别表示用户输入在模板中的占位符和历史消息在模板中的占位符。使用RunnableWithMessageHistory时，链的模板需要是ChatPromptTemplate，并且模板中需要包含一个MessagesPlaceholder占位符，用于注入历史消息

### 文件记忆

LangChain并没有提供现成的基于文件的历史记录组件，但我们可以通过继承BaseChatMessageHistory类来实现一个基于文件的历史记录组件。下面是一个简单的示例：

```python
class FileChatMessageHistory(BaseChatMessageHistory):
    def __init__(self, session_id, storage_path):
        self.session_id = session_id        # 会话id
        self.storage_path = storage_path    # 不同会话id的存储文件，所在的文件夹路径
        # 完整的文件路径
        self.file_path = os.path.join(self.storage_path, self.session_id)

        # 确保文件夹是存在的
        os.makedirs(os.path.dirname(self.file_path), exist_ok=True)

    def add_messages(self, messages: Sequence[BaseMessage]) -> None:
        # Sequence序列 类似list、tuple
        all_messages = list(self.messages)      # 已有的消息列表
        all_messages.extend(messages)           # 新的和已有的融合成一个list

        # 将数据同步写入到本地文件中
        # 类对象写入文件 -> 一堆二进制
        # 为了方便，可以将BaseMessage消息转为字典（借助json模块以json字符串写入文件）
        # 官方message_to_dict：单个消息对象（BaseMessage类实例） -> 字典
        # new_messages = []
        # for message in all_messages:
        #     d = message_to_dict(message)
        #     new_messages.append(d)

        new_messages = [message_to_dict(message) for message in all_messages]
        # 将数据写入文件
        with open(self.file_path, "w", encoding="utf-8") as f:
            json.dump(new_messages, f)

    @property       # @property装饰器将messages方法变成成员属性用
    def messages(self) -> list[BaseMessage]:
        # 当前文件内： list[字典]
        try:
            with open(self.file_path, "r", encoding="utf-8") as f:
                messages_data = json.load(f)    # 返回值就是：list[字典]
                return messages_from_dict(messages_data)
        except FileNotFoundError:
            return []

    def clear(self) -> None:
        with open(self.file_path, "w", encoding="utf-8") as f:
            json.dump([], f)
```

## 加载器

加载器Loader是一个特殊的组件，负责从外部资源（比如文件、数据库、API等）加载数据，并将其转换为LangChain中可用的格式

LangChain提供了很多内置的加载器，它们统一返回Document对象或者Document对象的列表，Document对象是LangChain中一个重要的数据结构，包含了文本内容、元数据等信息，可以被链中的其他组件使用

```python
document = Document(
    page_content="Hello, world!", metadata={"source": "https://example.com"}
)
```

加载器统一继承了BaseLoader抽象基类，包含很多方法，比如

- load()：一次性加载全部文档
- lazy_load()：延迟流式传输文档，对大型数据集很有用，避免内存溢出。

### CSVLoader

```python
loader: CSVLoader = CSVLoader(
    file_path="./data/stu.csv",
    csv_args={
        "delimiter": ",",       # 指定分隔符
        "quotechar": '"',       # 指定带有分隔符文本的引号包围是单引号还是双引号
        # 如果数据原本有表头，就不要下面的代码，如果没有可以使用
        "fieldnames": ['name', 'age', 'gender', '爱好']
    },
    encoding="utf-8"            # 指定编码为UTF-8
)

# 批量加载 .load()   ->  [Document, Document, ...]
documents: list[Document] = loader.load()

# 懒加载  .lazy_load()  迭代器[Document]
for document in loader.lazy_load():
    print(document)
```

### JSONLoader

```python
loader = JSONLoader(
    file_path="./data/stu_json_lines.json",
    jq_schema=".name",      # 使用jq语法指定从JSON对象中提取"name"字段的值作为文本内容
    text_content=False,     # 告知JSONLoader 我抽取的内容不是字符串
    json_lines=True         # 告知JSONLoader 这是一个JSONLines文件（每一行都是一个独立的标准JSON）
)

document = loader.load()
print(document)
```

这里说明一下jq_schema的写法

```javascript
JSON -> {"...": ...}
jq_schema -> "." # 提取整个JSON对象作为文本内容

JSON -> [{"text": ...}, {"text": ...}, {"text": ...}]
jq_schema -> ".[].text" # 提取JSON数组中每个对象的text字段作为文本内容

JSON -> {"key": [{"text": ...}, {"text": ...}, {"text": ...}]}
jq_schema -> ".key[].text" # 提取JSON对象中key字段对应的数组中每个对象的text字段作为文本内容

JSON -> ["...", "...", "..."]
jq_schema -> ".[]" # 提取JSON数组中每个元素作为文本内容
```

更多的可以参考<https://python.langchain.com.cn/docs/modules/data_connection/document_loaders/how_to/json>

### PyPDFLoader

```python
loader = PyPDFLoader(
    file_path="./data/pdf2.pdf",
    mode="single",        # 默认是page模式，每个页面形成一个Document文档对象，
                        # single模式，不管有多少页，只返回1个Document对象
    password="xxxxxx"  # 如果PDF文件有密码，可以通过password参数传入密码
)

i = 0
for document in loader.lazy_load():
    i += 1
    print(document)
    print("="*20, i)
```

PyPDFLoader只能加载PDF文件中的文本内容，无法提取图片、表格等非文本内容

### TextLoader

```python
loader = TextLoader(
    file_path="./data/text.txt",
    encoding="utf-8"
)
```

TextLoader是一个简单的文本加载器，可以将文本文件中的内容加载为Document对象。它支持指定编码格式

### 文本分割器RecursiveCharacterTextSplitter

用于按照段落自然分割大的Document对象，生成多个小的Document对象

```python
docs = loader.load()        # [Document]

splitter = RecursiveCharacterTextSplitter(
    chunk_size=500,         # 分段的最大字符数
    chunk_overlap=50,       # 分段之间允许重叠字符数
    # 文本自然段落分隔的依据符号
    separators=["\n\n", "\n", "。", "！", "？", ".", "!", "?", " ", ""],
    length_function=len,    # 统计字符的依据函数
)
documents = splitter.split_documents(docs)   # [Document, Document, ...]
```

## 向量操作

LangChain为向量存储提供了统一接口：

- add_documents # 存入document对象，类型：list[Document]
- delete        # 删除document对象，传入id列表，类型：list[str]
- similarity_search # 相似度搜索，返回相关document对象，类型：list[Document]

### 内存向量存储

```python
vector_store = InMemoryVectorStore(
    embedding=DashScopeEmbeddings()
)


loader = CSVLoader(
    file_path="./data/info.csv",
    encoding="utf-8",
    source_column="source",     # 指定本条数据的来源是哪里，CSV文件必须包含source这一列，否则抛出ValueError异常
)

documents = loader.load()
# id1 id2 id3 id4 ...
# 向量存储的 新增、删除、检索
vector_store.add_documents(
    documents=documents,        # 被添加的文档，类型：list[Document]
    ids=["id"+str(i) for i in range(1, len(documents)+1)] # 给添加的文档提供id（字符串）  list[str]
)

# 删除  传入[id, id...]
vector_store.delete(["id1", "id2"])

# 检索 返回类型list[Document]
result = vector_store.similarity_search(
    "瑞达法", # 检索的关键词
    3        # 检索的结果要几个
    filter={"source": "xxx"} # 可选参数，过滤条件，表示只检索来源是xxx的文档
)
```

### Chroma向量存储

```python
vector_store = Chroma(
    collection_name="test",     # 当前向量存储起个名字，类似数据库的表名称
    embedding_function=DashScopeEmbeddings(),       # 嵌入模型
    persist_directory="./chroma_db"     # 指定数据存放的文件夹
)
```

替换InMemoryVectorStore即可

## 将向量检索的内容嵌入大模型

### 向量检索结果的嵌入

```python
model = ChatTongyi(model="qwen3-max")
prompt = ChatPromptTemplate.from_messages(
    [
        ("system", "以我提供的已知参考资料为主，简洁和专业的回答用户问题。参考资料:{context}。"),
        ("user", "用户提问：{input}")
    ]
)

vector_store = InMemoryVectorStore(embedding=DashScopeEmbeddings(model="text-embedding-v4"))

# 准备一下资料（向量库的数据）
# add_texts 传入一个 list[str]
vector_store.add_texts(
    ["减肥就是要少吃多练", "在减脂期间吃东西很重要,清淡少油控制卡路里摄入并运动起来", "跑步是很好的运动哦"])

input_text = "怎么减肥？"

# 检索向量库
result = vector_store.similarity_search(input_text, 2)
reference_text = "["
for doc in result:
    reference_text += doc.page_content
reference_text += "]"

chain = prompt |  model | StrOutputParser()

res = chain.invoke({"input": input_text, "context": reference_text})
print(res)
```

这里我们先把用户的提问转换成向量在向量库检索相似内容，再把检索出来的内容作为**参考资料**context输入到提示词模板中，最后调用模型得到回答，这样就实现了向量检索结果的嵌入大模型的应用

但是这样还要我们自己手动进行检索和拼接参考资料的工作，能不能把这个过程也自动化掉呢？答案是可以的，我们可以把向量检索组件也加入到链中，这样在调用链的时候就不需要我们手动进行检索和拼接了，链条会自动帮我们完成这些工作

### RunnablePassThrough组件

```python
# langchain中向量存储对象，有一个方法：as_retriever，可以返回一个Runnable接口的子类实例对象
retriever = vector_store.as_retriever(search_kwargs={"k": 2})
# {"k": 2}表示检索的时候返回最相似的2条数据


def format_func(docs: list[Document]):
    if not docs:
        return "无相关参考资料"

    formatted_str = "["
    for doc in docs:
        formatted_str += doc.page_content
    formatted_str += "]"

    return formatted_str

# chain
chain = (
    {"input": RunnablePassthrough(), "context": retriever | format_func} | prompt | print_prompt | model | StrOutputParser()
)

res = chain.invoke(input_text)
print(res)
```

retriever是向量查询的一个链上组件，它的invoke方法会接受用户输入，进行向量检索，并返回相关的Document对象列表，我们通过自定义的format_func函数来把这个Document对象列表转换成一个字符串格式的参考资料，然后这个参考资料就会被传递给提示词模板中的占位符`{context}`

`RunnablePassThrough`是一个特殊的组件，它的作用是将输入数据原封不动地传递给下一个组件，而不进行任何处理。在上面的例子中，我们使用`RunnablePassThrough`来占位用户输入的位置，这样当我们调用链的时候，用户输入的数据就会直接传递给提示词模板中的占位符`{input}`，而不需要我们手动进行传递

因此，这条链的执行流程是：用户输入内容 ->  RunnablePassThrough直接把用户输入不做处理的嵌入`"input":`之后，`"context":`后面，用户的输入先经过retriever组件进行向量检索，得到相关的Document对象列表，再经过format_func函数把这个列表转换成一个字符串格式的参考资料，因此，第一部分的处理结果是

```json
{
    "input": "用户输入的原样内容",
    "context": "根据用户输入检索到的相关参考资料"
}
```

它作为一个字典对象，传递了链的下一个组件：提示词模板

## RAG综合

RAG服务部分

```python
def print_prompt(prompt):
    print("="*20)
    print(prompt.to_string())
    print("="*20)

    return prompt


class RagService(object):
    def __init__(self):

        self.vector_service = VectorStoreService(
            embedding=DashScopeEmbeddings(model=config.embedding_model_name)
        )

        self.prompt_template = ChatPromptTemplate.from_messages(
            [
                ("system", "以我提供的已知参考资料为主，"
                 "简洁和专业的回答用户问题。参考资料:{context}。"),
                ("system", "并且我提供用户的对话历史记录，如下："),
                MessagesPlaceholder("history"),
                ("user", "请回答用户提问：{input}")
            ]
        )

        self.chat_model = ChatTongyi(model=config.chat_model_name)

        self.chain = self.__get_chain()

    def __get_chain(self):
        """获取最终的执行链"""
        retriever = self.vector_service.get_retriever()

        def format_document(docs: list[Document]):
            """把检索到的文档列表格式化成字符串，作为prompt的一部分输入"""
            if not docs:
                return "无相关参考资料"

            formatted_str = ""
            for doc in docs:
                formatted_str += f"文档片段：{doc.page_content}\n文档元数据：{doc.metadata}\n\n"

            return formatted_str

        def format_for_retriever(value: dict) -> str:
            """retriever只需要input中的内容作为输入，所以这里需要把字典中的input部分提取出来，作为retriever的输入"""
            return value["input"]

        def format_for_prompt_template(value):
            # 因为你在"input"后面用了RunnablePassthrough，所以传入的字典被套上了一层input，
            # 所以这里需要把input中的input提取出来，作为prompt_template的输入，同时把context和history也提取出来，作为prompt_template的输入
            # {input, context, history}
            new_value = {}
            new_value["input"] = value["input"]["input"]
            new_value["context"] = value["context"]
            new_value["history"] = value["input"]["history"]
            return new_value

        chain = (
            {
                "input": RunnablePassthrough(),
                "context": RunnableLambda(format_for_retriever) | retriever | format_document
            } | RunnableLambda(format_for_prompt_template) | self.prompt_template | print_prompt | self.chat_model | StrOutputParser()
        )

        conversation_chain = RunnableWithMessageHistory(
            chain,
            get_history,
            input_messages_key="input",
            history_messages_key="history",
        )

        return conversation_chain
```

向量库服务部分

这个是给RAG用的，没有增加向量的功能

```python
class VectorStoreService(object):
    """向量数据库服务类，负责创建向量数据库对象(Chroma)，并提供获取向量检索器的方法"""
    def __init__(self, embedding):
        """
        :param embedding: 嵌入模型的传入
        """
        self.embedding = embedding

        self.vector_store = Chroma(
            collection_name=config.collection_name,
            embedding_function=self.embedding,
            persist_directory=config.persist_directory,
        )

    def get_retriever(self):
        """返回向量检索器，方便加入chain"""
        return self.vector_store.as_retriever(search_kwargs={"k": config.similarity_threshold})
```

这个是向量服务的管理类，有增加向量的功能

```python
def check_md5(md5_str: str):
    """检查传入的md5字符串是否已经被处理过了
        return False(md5未处理过)  True(已经处理过，已有记录）
    """
    if not os.path.exists(config.md5_path):
        # if进入表示文件不存在，那肯定没有处理过这个md5了
        open(config.md5_path, 'w', encoding='utf-8').close()
        return False
    else:
        # 遍历文件内的每一行，看看是否有和传入的md5字符串相同的，如果有则表示已经处理过了
        for line in open(config.md5_path, 'r', encoding='utf-8').readlines():
            line = line.strip()     # 处理字符串前后的空格和回车
            if line == md5_str:
                return True         # 已处理过
        # 遍历完了都没有找到相同的md5字符串，说明没有处理过
        return False

def save_md5(md5_str: str):
    """把MD5字符串保存到文件中，作为已经处理过的记录"""
    with open(config.md5_path, 'a', encoding="utf-8") as f:
        f.write(md5_str + '\n')

def get_string_md5(input_str: str, encoding='utf-8') -> str:
    """将字符串转换为16进制MD5字符串"""

    # 将字符串转换为bytes字节数组
    str_bytes = input_str.encode(encoding=encoding)

    # 创建md5对象
    md5_obj = hashlib.md5()     # 得到md5对象
    md5_obj.update(str_bytes)   # 更新内容（传入即将要转换的字节数组）
    md5_hex = md5_obj.hexdigest()       # 得到md5的十六进制字符串

    return md5_hex


class KnowledgeBaseService(object):
    """知识库服务类，负责处理知识库相关的向量化存储等"""
    def __init__(self):
        # 如果文件夹不存在则创建，如果存在则跳过
        os.makedirs(config.persist_directory, exist_ok=True)

        # 创建Chroma向量库对象
        self.chroma = Chroma(
            collection_name=config.collection_name,     # 数据库的表名
            embedding_function=DashScopeEmbeddings(model="text-embedding-v4"),
            persist_directory=config.persist_directory,     # 数据库本地存储文件夹
        )     # 向量存储的实例 Chroma向量库对象

        # 创建文本分割器对象
        self.spliter = RecursiveCharacterTextSplitter(
            chunk_size=config.chunk_size,       # 分割后的文本段最大长度
            chunk_overlap=config.chunk_overlap,     # 连续文本段之间的字符重叠数量
            separators=config.separators,       # 自然段落划分的符号
            length_function=len,                # 使用Python自带的len函数做长度统计的依据
        )     # 文本分割器的对象

    def upload_by_str(self, data: str, filename):
        """将传入的字符串，进行向量化，存入向量数据库中"""
        # 先得到传入字符串的md5值
        md5_hex = get_string_md5(data)

        if check_md5(md5_hex):
            return "[跳过]内容已经存在知识库中"

        if len(data) > config.max_split_char_number:
            knowledge_chunks: list[str] = self.spliter.split_text(data)
        else:
            knowledge_chunks = [data]

        metadata = {
            "source": filename,
            # 2025-01-01 10:00:00
            "create_time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "operator": "小曹",
        }

        self.chroma.add_texts(      # 内容就加载到向量库中了
            # iterable -> list \ tuple
            knowledge_chunks,
            metadatas=[metadata for _ in knowledge_chunks],
        )

        #
        save_md5(md5_hex)

        return "[成功]内容已经成功载入向量库"
```

## Agent
