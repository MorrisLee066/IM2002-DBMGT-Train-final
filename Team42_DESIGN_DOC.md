# Database Design Document

## Section 1 — Entity-Relationship Diagram
![TransitFlow ERD Main](https://github.com/MorrisLee066/my-homework-images/blob/main/Transitflow%20ERD%20v4.0_page-0002.jpg?raw=true)
![TransitFlow ERD Main](https://github.com/MorrisLee066/my-homework-images/blob/main/Transitflow%20ERD%20v4.0_page-0003.jpg?raw=true)
## Section 2 — Normalisation Justification
### Normalisation Decision
### De-normalisation Trade-off
### Password Hashing Strategy
## Section 3 — Graph Database Design Rationale
### Nodes, Relationships, and Properties
### Graph vs. Relational Argument
### Supported Query Types
### Node Identity
## Section 4 — Vector / RAG Design

### Embedded Content & Similarity Metric
我們的 RAG (Retrieval-Augmented Generation) 知識庫主要負責處理系統的政策文件 (Policy documents)。在實作任務上，我們專注於知識庫的領域資料擴充，特別針對 `train-mock-data/` 目錄下的四個核心規則檔（`booking_rules.json`, `refund_policy.json`, `ticket_types.json`, `travel_policies.json`）進行了客製化規則撰寫，系統會將這些文字轉換為 Embeddings 並存入 PostgreSQL 的 vector 欄位中。

在檢索這些擴充後的政策文件時，系統底層的查詢邏輯採用了 **Cosine Similarity** (`<=>`) 運算子。理解這個底層機制的優勢非常重要：文字語意在高維度空間中，重點在於兩者的「方向」是否一致，也就是 **directional similarity**。Cosine similarity 的數學特性是 **magnitude-independent** (與大小/長度無關)，這代表即使使用者的問題很短（例如「延誤賠償」），而政策文件包含長達數百字的詳細條款，只要它們討論的核心概念方向一致，演算法就能準確抓出這份文件，從而避免了傳統歐幾里得距離 (L2 distance) 容易因為字數長度差異而導致的檢索失真。

### The RAG Pipeline
我們的系統在處理政策詢問時，完整經過以下四個階段的 Pipeline：

1. **Query Embedding:** 當接收到使用者的自然語言問題（例如 "What is the refund policy for a delayed train?"），系統會先呼叫 Embedding model，將這句話轉化為數值向量。
2. **Similarity Search:** 接著，將這個「問題向量」傳入 PostgreSQL，利用 `pgvector` 執行 Cosine 相似度比對（`ORDER BY embedding <=> %s::vector`），計算出距離最近的 Top-K 筆資料。
3. **Retrieved Documents:** 資料庫回傳最相關的原始文件內容（例如從 `refund_policy.json` 中檢索出的特定退款條款）。
4. **LLM Prompt & Answer:** 系統將這些檢索到的政策文字作為 Context（背景知識），連同使用者原本的問題，一起注入 (Inject) 到預先寫好的 LLM Prompt 模板中。最後 LLM 會嚴格基於我們提供的 Context 進行推論，生成精準且不產生幻覺的最終 Answer。

### Embedding Dimension 
在維度大小的選擇上，因為我們本地端選用 Ollama (`nomic-embed-text`) 作為 embedding 提供者，因此資料庫的 vector 欄位維度設定為 **768**。

如果我們在資料庫完成 seeding 之後，因為效能考量而中途將模型提供者切換為 Gemini（其維度為 **3072**），系統將面臨災難性的錯誤。由於 PostgreSQL 的欄位已經被硬性限制為 `vector(768)`，Gemini 產生的 3072 維度查詢向量將無法與現有資料庫進行比對。這種 **dimension mismatch (維度不匹配)** 會直接導致相似度搜尋崩潰，使得原本建立的 index 完全失效 (unusable)。在實務上，若要更換 Provider，我們必須清空整個 Vector 資料表、修改 Schema 定義，並重新消耗算力對所有的 JSON 文件重新進行 Embedding。
## Section 5 — AI Tool Usage Evidence
### Example 1: [寫明這是 Schema 設計、Query 撰寫還是 Debug]
* **Context:** (你當時想解決什麼問題)
* **Prompt:** (你餵給 AI 的具體提示詞)
* **Outcome:** (AI 回答了什麼、是否有效、你後續做了什麼修改)

### Example 2: [填寫主題]
* **Context:** * **Prompt:** * **Outcome:** ### Example 3: [填寫主題 - 必須包含 AI 犯錯並被你修正的例子]
* **Context:** * **Prompt:** * **Outcome:** (重點描述 AI 哪裡錯了，你怎麼修好的)

## Section 6 — Reflection & Trade-offs
### Design Decisions
### Production Considerations
## Section 7 — Task 6 Extension (Optional)
### Motivation
### Database Changes
### Example Queries
### Testing Evidence