# Database Design Document

## Section 1 — Entity-Relationship Diagram

![TransitFlow relational ERD](https://github.com/MorrisLee066/my-homework-images/blob/main/Transitflow%20ERD%20v4.0_page-0002.jpg?raw=true)

*Figure 1.1. Main relational entity-relationship diagram.*

![TransitFlow supporting entities and enums](https://github.com/MorrisLee066/my-homework-images/blob/main/Transitflow%20ERD%20v4.0_page-0003.jpg?raw=true)

*Figure 1.2. Enumeration types used in the TransitFlow relational schema.*

## Section 2 — Normalisation Justification

### 2.1 Third Normal Form（3NF）：將 Stations 與 Bookings 分離

在 `national_rail_bookings` table 中，我們只儲存 `origin_station_id` 與 `destination_station_id` 作為 Foreign Keys，而不直接重複儲存 station name、interchange information 或 line membership 等車站描述資料。

Booking record 由 Primary Key `id` 唯一識別，而車站描述資料則依賴 station key：

```text
booking.id → origin_station_id → national_rail_stations.name
booking.id → destination_station_id → national_rail_stations.name
```

若將 station name 直接存入每一筆 booking row，便會形成 Transitive Dependency。當車站名稱被修改時，系統必須同步更新多筆 booking records，否則容易造成歷史資料不一致與 Update Anomaly。

因此，我們將 station details 保留在 `national_rail_stations`，並於查詢時透過 Foreign Key Join 取得。此設計移除了 transitive dependency，使 `national_rail_bookings` 符合 Third Normal Form（3NF）。

相同原則也應用在 User Authentication。一般 user profile data 儲存在 `users`，而 password hash 與 security-answer hash 則獨立存放於 `user_credentials`。

兩者之間為 One-to-One Relationship，因為 `user_credentials.user_id` 同時是 Primary Key 與指向 `users.id` 的 Foreign Key。如此可確保 authentication data 僅依賴 candidate key `user_id`，且不會被重複儲存在 profile、booking 或 payment records 中。

### 2.2 Second and Third Normal Form（2NF／3NF）：以 Junction Tables 儲存 Schedule Stops

一個 schedule 會包含一組具有順序的 stations。TransitFlow 使用 `metro_schedule_stops` 與 `national_rail_schedule_stops` 兩張 Junction Tables 儲存這些資料，而不是將所有停靠站放入 comma-separated string 或 JSON array。

以 `national_rail_schedule_stops` 為例，其 Candidate Key 為：

```text
(schedule_id, stop_order)
```

並額外設定：

```text
UNIQUE (schedule_id, station_id)
```

`station_id` 與 `travel_time_from_origin_min` 描述的是「某一個 schedule 中的某一個 stop」，因此它們依賴完整的 composite key，而不是只依賴 `schedule_id` 或 `stop_order` 其中之一。這樣可避免 Partial Dependency，符合 Second Normal Form（2NF）。

此外，station name 與其他 descriptive attributes 仍保留於 `national_rail_stations`，因此 schedule-stop table 不會出現：

```text
schedule-stop key → station_id → station description
```

這類 Transitive Dependency，因而也符合 Third Normal Form（3NF）。

此設計具有以下優點：

- 支援任意數量的 stops；
- 保留正確的 stop order；
- 透過 Foreign Keys 維持 Referential Integrity；
- 支援 origin 與 destination 的位置比較；
- 相較於 array column，更容易建立 Index 與執行資料驗證。

### 2.3 Normalising Fare Classes and Seat Layouts

National rail fare rules 被獨立儲存在 `national_rail_fares`，而不是在 `national_rail_schedules` 中建立多組重複的 fare columns。

其 Composite Primary Key 為：

```text
(schedule_id, fare_class)
```

這組 key 可唯一識別某一個 schedule 中的一種 fare rule，而 `base_fare_usd` 與 `per_stop_rate_usd` 都完整依賴此 composite key。

同樣地，`national_rail_seats` 使用：

```text
(schedule_id, seat_code)
```

作為 Candidate Key。`coach`、`fare_class`、`seat_row` 與 `seat_column` 都描述特定 schedule layout 中的一個特定 seat。

此設計可避免在每一筆 booking 中重複儲存完整 seat layout，並讓 booking 透過 Composite Foreign Key 只參照有效的座位資料。

### 2.4 Deliberate De-normalisation Trade-offs

雖然 `stops_travelled`、`origin_stop_order` 與 `destination_stop_order` 可以從 `national_rail_schedule_stops` 推導，但 TransitFlow 仍選擇將這些欄位保留在 `national_rail_bookings` 中。

這是一項 Controlled De-normalisation Decision，主要目的是簡化並加速 Seat Conflict Check。

區段重疊條件如下：

```text
existing.origin_stop_order < requested_destination_stop_order
AND existing.destination_stop_order > requested_origin_stop_order
```

若每次 availability check 或 conflict check 都重新 Join schedule-stop table，系統會產生額外的查詢成本。將 stop positions 儲存在 booking row 中，可直接進行 segment overlap comparison。

這些值並不是由 user input 直接提供，而是由 `execute_booking()` 從已驗證的 schedule-stop records 中計算後寫入，因此可以降低資料不一致的風險。

另外，`amount_usd` 也被儲存為 Historical Financial Snapshot。雖然金額最初可由 `national_rail_fares` 計算，但 confirmed booking 必須保留當下的實際價格，即使 fare rule 日後有所調整，也不應改變既有交易紀錄。

這對下列功能十分重要：

- Payment Records
- Refund Processing
- Booking History
- Accounting Reports

此類 copied values 確實可能產生 consistency risk，因此 TransitFlow 透過 controlled booking operation 計算這些值，並將 booking 與 payment 放在同一個 Atomic Transaction 中完成。

### 2.5 Password Hashing Strategy

TransitFlow 使用 `argon2-cffi` 套件中的 `PasswordHasher` class，並採用 **Argon2id** 作為 Password Hashing Algorithm。

Argon2id 是一種專為密碼設計的 Memory-Hard Key Derivation Function。與 MD5 或 SHA-1 這類快速的 general-purpose hash functions 不同，Argon2id 可設定每次 password guess 所需的 computation time 與 memory usage，因此能提高 GPU 或 specialised hardware 執行大規模 brute-force attacks 的成本。

當使用者註冊或重設密碼時，application 會呼叫：

```python
PasswordHasher.hash()
```

Argon2id 會自動為每個 password 產生 random salt，並將以下資訊一起存放於 encoded output：

- Algorithm Version
- Hashing Parameters
- Salt
- Derived Hash

因此，不需要額外建立獨立的 salt column。

Salt 可確保兩位使用者即使設定相同密碼，例如 `Transit123`，最終儲存的 hash 仍會不同。這能防止攻擊者透過比較 hash 判斷使用者是否使用相同密碼，也能抵抗 precomputed rainbow-table lookups。

登入時，TransitFlow 透過：

```python
PasswordHasher.verify()
```

驗證輸入密碼與 encoded hash。Plaintext Password 不會被儲存。

此外，authentication credentials 與 general user profile 分離，也能減少一般 profile query 不必要地接觸敏感驗證資料。

## Section 3 — Graph Database Design Rationale

### Nodes, Relationships, and Properties

在我們的系統架構中，圖形資料被策略性地拆分為 Nodes、Relationships 與 Properties 三個層次，並各自具備明確的設計理由：

- **節點（Nodes）**：我們將車站儲存為 Nodes，並明確定義 `MetroStation` 與 `NationalRailStation` 兩種不同的 Labels。這項設計能將捷運與國鐵兩個路網在邏輯上解耦（Decouple），讓查詢可針對特定類型的車站進行 Label Filtering，避免在單一路網查詢中不必要地掃描其他類型的節點。
- **關係（Relationships）**：實體軌道與轉乘通道被建立為 Relationships，包含 `METRO_LINK`、`RAIL_LINK`，以及作為跨網橋樑的 `INTERCHANGE_WITH`。這些 Edges 本質上代表旅客可以實際移動的路徑，因此適合用於 route traversal、interchange exploration 與 path-finding operations。
- **屬性（Properties）**：Station Nodes 主要保留描述性 metadata，例如 `station_id`、`name` 與 `lines`；而 `travel_time_min`、`fare` 與 `fare_first` 等成本資料則儲存在 Relationships 上。這些 values 可作為 Edge Weights，供 minimum-cost path algorithms 使用。

### Graph and Relational Database Comparison

對於 multi-hop traversal 與未知深度的 route exploration，Graph Database 通常能以更自然的方式表達車站之間的連通關係。在 Neo4j 中，Relationships 以 native graph structure 儲存，查詢可以直接沿著相鄰 Relationships 進行 traversal。

相較之下，在 PostgreSQL 等 Relational Database 中，未知深度的路徑搜尋通常需要 Recursive CTEs 與 repeated JOIN operations。隨著 route depth 與 candidate paths 增加，查詢表達及中間結果管理可能變得較為複雜。

因此，TransitFlow 將 routing、interchange exploration 與 delay-impact traversal 放在 Neo4j 中處理，而將 users、bookings、payments 與 timetable records 等具明確結構及 transactional requirements 的資料保留在 PostgreSQL。這項設計是依據兩種 database models 各自適合的 query patterns 進行分工，而不是假設 Graph Database 在所有情境下都一定具有較高效能。

### Core Query Types

TransitFlow 的 graph model 支援以下兩種主要 query types：

- **Minimum-Cost Path Query**：Relationships 儲存 `travel_time_min`、`fare` 與 `fare_first`。由於這些 Edge Weights 為 non-negative values，系統可以使用 Dijkstra algorithm，分別以 travel time 或 fare 作為 cost function，計算目前 graph data 下的 minimum-cost path。
- **Delay Ripple Analysis**：當某一車站或 route segment 發生延誤時，系統可以利用 Variable-Length Path Syntax，例如 `*1..15`，探索指定 hop range 內可能受到影響的周邊車站。此查詢提供 network impact analysis 所需的候選範圍，但實際延誤程度仍須配合 operational data 判斷。

### Node Identity Design

在 Node Identity 的設計上，我們使用 `station_id` 作為唯一的 Identity Property。該欄位保存來源資料中的穩定 Business Identifier，例如 `MS01` 或 `NR01`，並可對應至 PostgreSQL 中的 `station_code`。這項設計能維持 PostgreSQL 與 Neo4j 之間的 cross-database consistency。

此外，在資料匯入腳本 `seed_neo4j.py` 中，系統使用 `station_id` 作為 `MERGE` 語法的比對條件。當 seeding script 被重複執行時，Neo4j 會匹配既有 Node，而不是建立相同車站的 duplicate nodes，因此支援 idempotent seeding。

## Section 4 — Vector / RAG Design

### Embedded Content & Similarity Metric

我們的 RAG（Retrieval-Augmented Generation）知識庫主要負責處理系統的政策文件（Policy Documents）。在實作任務上，我們專注於知識庫的 domain data extension，特別針對 `train-mock-data/` 目錄下的四個核心規則檔：`booking_rules.json`、`refund_policy.json`、`ticket_types.json` 與 `travel_policies.json`。系統會將這些文字轉換為 Embeddings，並存入 PostgreSQL 的 vector 欄位中。

在檢索政策文件時，系統使用 pgvector 的 cosine distance operator `<=>` 比較 query embedding 與 document embedding。Cosine distance 越小，代表兩個向量在高維空間中的方向越接近；程式再透過 `1 - cosine distance` 將距離轉換為 similarity score。

Cosine-based retrieval 著重向量方向，而不是向量 magnitude，因此適合比較不同長度文字的 semantic relationship。即使使用者問題較短，而 policy document 較長，只要兩者的 embedding directions 相近，系統便較有機會將語意相關的文件排在檢索結果前方。

不過，retrieval quality 仍會受到 embedding model、document chunking、Top-K、similarity threshold 與 query ambiguity 等因素影響，因此 similarity search 並不保證每次都能取得完全正確的文件。

### The RAG Pipeline

系統在處理政策詢問時，會依序經過以下四個階段：

1. **Query Embedding:** 當系統接收到使用者的自然語言問題，例如 `"What is the refund policy for a delayed train?"`，會先呼叫 Embedding Model，將文字轉換為數值向量。
2. **Similarity Search:** 系統將 query vector 傳入 PostgreSQL，使用 `ORDER BY embedding <=> %s::vector` 依 cosine distance 排序，取得距離最近的 Top-K documents。
3. **Retrieved Documents:** Database 回傳最相關的原始政策內容，例如從 `refund_policy.json` 中檢索出的退款條款。
4. **LLM Prompt & Answer:** 系統將 retrieved policy documents 作為 Context，連同使用者原本的問題一起注入 LLM Prompt。LLM 會根據 retrieved context 產生 grounded answer，以提升回答與政策文件的一致性，並降低 hallucination 的風險。

### Embedding Dimension

目前系統使用 Ollama 的 `nomic-embed-text`，因此 PostgreSQL 欄位設定為 `vector(768)`。

若切換至輸出 3072-dimensional embeddings 的 provider，例如 Gemini，新的 query vector 將無法與現有 `vector(768)` 欄位進行距離計算，查詢會因 dimension mismatch 而失敗。

若要切換 Embedding Provider，必須修改 Schema 中的 vector dimension、重新產生全部 document embeddings，並重建相關的 vector index。

## Section 5 — AI Tool Usage Evidence

### Example 1: Fixing AI's Oversight on Graph Weights & Error Handling (Error Correction)

* **Context:** 我們的團隊分工處理圖形資料庫：一位組員使用 AI 生成 `queries.py` (Cypher queries)，另一位則用 AI 生成 `seed_neo4j.py` (data ingestion)。在系統整合與 Code Review 時，我們發現了一個嚴重的跨檔案邏輯錯誤 (cross-file logic bug)。AI 生成的 `queries.py` 呼叫了 `apoc.algo.dijkstra` 來計算最短路徑 (shortest-path) 與最便宜路線 (cheapest-route)，但 AI 生成的 `seed_neo4j.py` 卻漏掉為 `INTERCHANGE_WITH` 的關係 (relationships) 賦予 `travel_time_min` 和 `fare` 屬性。這個「權重陷阱（weight trap）」可能導致演算法執行失敗或產生不正確的路徑成本。此外，AI 也沒有在資料庫操作中實作 `try...except` 區塊，嚴重違反了我們的團隊合約 (team contract)。
* **Prompt:** *"請為我補全所有的部分，同時我的組員指出有三個問題 隱患 1：APOC Dijkstra 演算法的「權重陷阱」(最嚴重)... 轉乘沒有時間... 沒有票價 (Fare) 屬性... 隱患 2：嚴重違反了團隊合約的 Try-Catch 規定... 隱患 3：多餘的 `INTERCHANGE_TO` relationship type..."*
* **Outcome:** AI 承認了這個跨檔案整合的盲點並修正了先前的輸出。它更新了 `seed_neo4j.py`，在處理轉乘的 `MERGE` 語句中補上了 `SET r.travel_time_min = 5` 以及預設票價 (`fare`, `fare_first`)。同時，它也重寫了 `queries.py` 中的所有函數，加入了 `try...except` error handling，避免未處理的 database exceptions 直接向上傳遞，並清除了不存在的 `INTERCHANGE_TO` relationship type。這個案例顯示，當 AI 分別處理相互依賴的檔案時，人類進行 cross-file review 與 systematic debugging 仍十分重要。

### Example 2: Debugging Agent Integration & DTO Implementation via SQL Aliases (Error Correction)

* **Context:** 在本機端驗證完 Database layer 後，我們將其與 LLM Agent 和 Gradio 前端 (frontend) 進行整合。系統在登入後的階段發生崩潰，當 Agent 試圖獲取使用者 Session 詳細資訊時，在終端機拋出了 `KeyError`。我提取了原始的 traceback 來對這個介面合約不匹配 (interface contract mismatch) 的問題進行除錯。
* **Prompt:** *"(Pasted Terminal Error): File "/home/morrislee/transitflow/skeleton/agent.py", line 552, in run_agent user_display = f"{profile['full_name']} (email: {current_user_email}, user_id: {profile['user_id']})" KeyError: 'user_id' (My Architectural Question): 還有這麼多類似問題，為甚麼當初要自己取跟 json 檔中屬性不一樣的名字？"*
* **Outcome:** AI 分析了 traceback 並揪出核心問題：我們的 dual-identifier design（internal key 與 business key 並存）與前端 Agent 產生了架構衝突 (architectural conflict)。我們的 Schema 刻意使用明確的名稱如 `user_code` 作為業務金鑰 (business keys)，而前端 Agent 卻硬編碼 (hardcoded) 預期會收到 `user_id` 這種通用欄位。為了在不修改既有 Database Schema 的情況下維持前端介面相容性，AI 建議使用 SQL 別名 (SQL aliases, 例如 `SELECT user_code AS user_id`) 來實作資料傳輸物件 (Data Transfer Object, DTO) 模式。此解法消除了前端的欄位不相容問題，同時保留了資料庫的 structural integrity。

### Example 3: Correcting AI-Generated Neo4j Relationship Processing (Error Correction)

* **Context:** 我的組員使用 AI 工具生成 Neo4j 的路徑查詢與 Python-side result processing（`databases/graph/queries.py`）。在測試 cross-network paths 時，資料庫雖然成功找到正確車站，卻持續回傳空的 `interchange_points` array，進而讓 UI Agent 產生不正確的轉乘說明。因此，我們擷取相關程式碼並要求 AI 重新進行 Code Review。
* **Prompt:** *"[附上包含 `type(r) == 'INTERCHANGE_WITH'` 的 Python-side relationship processing 程式碼片段] 組員寫的真的有 bug 嗎？"*
* **Outcome:** AI 指出原始錯誤發生在 Python-side result processing。呼叫 Python 內建的 `type(r)` 會回傳 Relationship object 的 class，例如 `<class 'neo4j.graph.Relationship'>`，而不是 Neo4j relationship type，因此與字串 `'INTERCHANGE_WITH'` 的比較會失敗。修正後，Python 程式改用 `r.type` 取得 relationship type。

  相對地，`type(r)` 在 Cypher query 中仍是合法且正確的 Neo4j function。因此，最終實作在 Cypher 中保留 `type(r)`，並在 Python 處理 Relationship objects 時使用 `r.type`。此修正解決了空陣列問題，也降低了 Agent 根據不完整 routing data 產生錯誤回覆的風險。

---

## Section 6 — Reflection & Trade-offs
### 6.1 Design Decisions
#### 6.1.1 Hybrid Surrogate-Key Strategy

TransitFlow 採用 Hybrid Surrogate-Key Strategy。

對於 centrally managed 且相對穩定的 infrastructure tables，例如 stations、lines 與 schedules，我們使用 `SERIAL` integer surrogate keys。Integer keys 具有儲存空間小、Index 效率高，以及適合大量 Join Operations 等優點。

另一方面，`RU01`、`NR01` 與 `NR_SCH01` 等 user-facing identifiers 被保留為 Unique Business Keys，而不是直接作為 physical primary keys。

Transactional Records 則在適當情況下使用 application-generated UUID-based identifiers。這樣可以避免對外暴露可預測的 sequential transaction numbers，同時保留 mock data 原有識別碼的穩定性與可讀性。

此設計的 Trade-off 是：同一張 table 可能同時包含 internal surrogate key 與 external business identifier，因此需要額外的 Unique Constraint，某些查詢也可能多一次 lookup。

然而，這能清楚分離 Database Identity 與 Business Meaning，並降低未來 business identifier 變更時對 relational references 的影響。
#### 6.1.2 Normalised Stops with Selected Transaction Snapshots

Schedule stops 被完整 Normalised 至 Junction Tables，因為 stop order、station membership 與 travel-time offset 都必須可被獨立查詢與驗證。

但在 booking records 中，我們仍選擇保留部分 derived values，例如：

- Stop Positions
- Stops Travelled
- Paid Amount

此設計刻意在 Data Consistency 與 Operational Efficiency 之間取得平衡。

Normalised Schedule Data 仍是 Authoritative Source，而 booking rows 則保留 seat overlap check 與 historical financial record 所需的資訊。

其缺點是，如果 copied values 被繞過 controlled transaction 直接修改，可能會與原始 schedule data 不一致。因此，application 會在 booking operation 中統一計算這些欄位，並將 booking 與 payment 一次 commit。

### 6.2 Production Considerations

在 Production Environment 中，我們不會透過重新執行 `schema.sql` 並重建整個 database 的方式進行 schema changes。

正式系統應使用 Versioned Migration Tool，例如：

- Alembic
- Flyway

這樣可以逐步新增 columns、constraints 與 indexes，而不必刪除既有 bookings 或 payments。

每一個 migration 都應先在 Staging Environment 中測試，並準備 Rollback Plan 或 Recovery Plan。

此外，production system 也應採用 Connection Pooling，而不是每次 database operation 都重新建立 PostgreSQL connection。

Database credentials 與 passwords 應儲存在 Managed Secret Service 中，而不是放在 local `.env` file。

系統也應增加 Monitoring，包含：

- Failed Transactions
- Connection Usage
- Slow Queries
- Advisory-Lock Contention

Course Project 運行於小型 local environment，但 production service 必須支援 concurrent users、controlled releases 與 secure secret management，因此上述改善對正式部署十分重要。

## Section 7 — Task 6 Extension (Optional)

### 7.1 Motivation

Task 6 Extension 新增了 **Frequency-Based National Rail Departure-Time Validation**。

原始 mock schedule data 並不是為每一個 departure 建立一筆獨立資料，而是透過以下三個欄位表示 repeating service：

- `first_train_time`
- `last_train_time`
- `frequency_min`

在此 extension 完成之前，完整的 service window 尚未被完全保留，booking layer 也可能收到一個並非由所選 schedule 推導出的 departure time。

因此，此 extension 主要改善以下四點：

1. 在 availability results 中回傳 valid departure times；
2. 根據 selected origin station 的 `travel_time_from_origin_min` 調整時間；
3. 在建立 booking record 前拒絕 missing 或 invalid departure time；
4. 讓 availability query 與 booking validation 共用相同的 time-generation logic。

此設計不需要在 database 中 materialise 大量 departure rows。PostgreSQL 只儲存一次 service window，而 application 在需要時動態產生 valid departures。

### 7.2 Database Changes

#### Schedule Schema

`national_rail_schedules` 會儲存 first train、last train 與 frequency：

```sql
CREATE TABLE national_rail_schedules (
    id               SERIAL PRIMARY KEY,
    schedule_code    VARCHAR(50) UNIQUE NOT NULL,
    line_id          INTEGER NOT NULL
                     REFERENCES national_rail_lines(id) ON DELETE RESTRICT,
    service_type     service_type_enum NOT NULL,
    direction        direction_enum NOT NULL,
    first_train_time TIME,
    last_train_time  TIME,
    frequency_min    INTEGER,
    operates_on      TEXT[] NOT NULL
);
```

Origin-station offset 則由：

```text
national_rail_schedule_stops.travel_time_from_origin_min
```

提供：

```sql
CREATE TABLE national_rail_schedule_stops (
    schedule_id                 INTEGER NOT NULL,
    station_id                  INTEGER NOT NULL,
    stop_order                  INTEGER NOT NULL,
    travel_time_from_origin_min INTEGER NOT NULL,
    PRIMARY KEY (schedule_id, stop_order),
    UNIQUE (schedule_id, station_id)
);
```

#### Seed Data

`skeleton/seed_postgres.py` 會從 `national_rail_schedules.json` 讀取 timetable fields：

```python
schedules.append((
    schedule_code,
    line_code,
    item.get("service_type"),
    item.get("direction"),
    item.get("first_train_time"),
    item.get("last_train_time"),
    item.get("frequency_min"),
    item.get("operates_on", []),
))
```

接著將這些 values 寫入 PostgreSQL：

```sql
INSERT INTO national_rail_schedules (
    schedule_code,
    line_id,
    service_type,
    direction,
    first_train_time,
    last_train_time,
    frequency_min,
    operates_on
)
SELECT
    data.sch_code,
    nl.id,
    data.srv::service_type_enum,
    data.dir::direction_enum,
    data.first_time::time,
    data.last_time::time,
    data.freq::int,
    data.ops::text[]
FROM (VALUES %s) AS data(
    sch_code,
    ln_code,
    srv,
    dir,
    first_time,
    last_time,
    freq,
    ops
)
JOIN national_rail_lines nl
    ON nl.line_code = data.ln_code;
```

#### Departure-Time Generation

`_generate_departure_times()` 會先將 first train 與 last train 依 selected origin station 的 offset 進行平移，再持續加上 `frequency_min`：

```python
def _generate_departure_times(
    first_train_time,
    last_train_time,
    frequency_min: int,
    origin_offset_min: int = 0,
) -> list[str]:
    if not frequency_min or frequency_min <= 0:
        return []

    first_train_time = first_train_time or time(6, 0)
    last_train_time = last_train_time or time(23, 0)

    if isinstance(first_train_time, str):
        first_train_time = datetime.strptime(first_train_time, "%H:%M").time()
    if isinstance(last_train_time, str):
        last_train_time = datetime.strptime(last_train_time, "%H:%M").time()

    current = (
        datetime.combine(datetime.today(), first_train_time)
        + timedelta(minutes=origin_offset_min or 0)
    )
    end = (
        datetime.combine(datetime.today(), last_train_time)
        + timedelta(minutes=origin_offset_min or 0)
    )

    departure_times = []
    while current <= end:
        departure_times.append(current.strftime("%H:%M"))
        current += timedelta(minutes=frequency_min)

    return departure_times
```

The default `06:00–23:00` service window is retained only as a defensive fallback for incomplete legacy data. Under normal operation, the departure window is read from the seeded schedule record.

`query_national_rail_availability()` 會回傳 generated departure-time list，而 `execute_booking()` 在插入 booking 前，也會重新產生相同清單並進行 validation。

Missing departure time 會被拒絕：

```python
if not requested_departure:
    conn.rollback()
    return False, {
        "success": False,
        "error": "Missing departure_time",
        "message": "A departure time is required for frequency-based booking.",
    }
```

Invalid departure time 也會被拒絕：

```python
if requested_departure not in valid_hhmm:
    conn.rollback()
    return False, {
        "success": False,
        "error": "Invalid departure_time",
        "message": (
            f"The requested departure time {departure_time} is not available "
            f"for schedule {schedule_id} on {travel_date}."
        ),
        "available_departure_times": valid_departure_times,
    }
```

Booking 與 Payment 仍維持在同一個 Atomic Transaction 中。

此外，原有的 Segment-Based Seat Conflict Detection 也被保留，以確保同一個 schedule、travel date 與 departure time 下，相同 seat 不會被指派給互相重疊的 journey segments。

### 7.3 Example Queries and Expected Output

#### Example A — Verify Seeded Timetable Fields

```sql
SELECT
    schedule_code,
    first_train_time,
    last_train_time,
    frequency_min
FROM national_rail_schedules
ORDER BY schedule_code;
```

Expected Output Pattern：

```text
schedule_code | first_train_time | last_train_time | frequency_min
--------------+------------------+-----------------+--------------
NR_SCH01      | 06:00:00         | 22:30:00        | 30
```

#### Example B — Retrieve Generated Departure Times

```python
from databases.relational.queries import query_national_rail_availability

rows = query_national_rail_availability(
    origin_id="NR01",
    destination_id="NR05",
    travel_date="2026-07-01",
)

print(rows[0]["schedule_id"])
print(rows[0]["departure_times"][:5])
```

Expected Output：

```text
NR_SCH01
['06:00', '06:30', '07:00', '07:30', '08:00']
```

#### Example C — Reject an Invalid Departure Time

```python
ok, result = execute_booking(
    user_id="RU01",
    schedule_id="NR_SCH01",
    origin_station_id="NR01",
    destination_station_id="NR05",
    travel_date="2026-07-01",
    departure_time="03:00",
    fare_class="standard",
    seat_id="any",
)

print(ok)
print(result)
```

Expected Output Pattern：

```text
False
{
  'success': False,
  'error': 'Invalid departure_time',
  'available_departure_times': [...]
}
```

#### Example D — Confirm Transaction Integrity after a Rejected Conflict

```sql
SELECT
    COUNT(DISTINCT b.id) AS booking_count,
    COUNT(DISTINCT p.id) AS payment_count
FROM national_rail_bookings b
LEFT JOIN payments p
    ON p.rail_booking_id = b.id
WHERE b.travel_date = DATE '2026-07-01'
  AND b.departure_time = TIME '06:00'
  AND b.seat_code = 'B01';
```

重複 booking 被拒絕後，Expected Output 為：

```text
booking_count | payment_count
--------------+--------------
1             | 1
```

### 7.4 Testing Evidence

下列 PostgreSQL result 證明 schedule service-window fields 已成功建立並完成 seeding。

![Schedule time fields stored in PostgreSQL](https://iili.io/CC5CoSp.md.png)

*Figure 7.1. PostgreSQL 中儲存的 `first_train_time`、`last_train_time` 與 `frequency_min`。*

Availability test 成功回傳 `NR_SCH01` 的 non-empty valid departure list。

![Availability query with generated departure times](https://iili.io/CC5CzHN.md.png)

*Figure 7.2. 根據 stored schedule window 與 frequency 產生的 departure times。*

當 booking request 使用 `03:00` 時，系統拒絕該時間，並回傳 valid departure alternatives。

![Invalid departure time rejected](https://iili.io/CC5CnlR.md.png)

*Figure 7.3. Invalid departure-time validation。*

使用 `06:00` 的 valid booking 成功產生 booking reference 與 linked payment reference。Booking status 為 confirmed，payment status 為 paid。

![Valid booking and payment created](https://iili.io/CC5CqiJ.md.png)

*Figure 7.4. Booking 與 Payment 在同一個 transaction 中成功建立。*

第二次嘗試預訂同一個 seat 且 journey segment 發生重疊時，系統成功拒絕該 request。Cancellation 與 refund operation 也成功執行。

![Double booking and refund test](https://iili.io/CC5C2N1.md.png)

*Figure 7.5. Double-booking prevention 與 successful cancellation/refund processing。*

直接執行 PostgreSQL query 後，確認 successful booking 與 payment 之間的 relationship 正確存在。

![Single booking and linked payment](https://iili.io/CC5CKog.md.png)

*Figure 7.6. One booking record linked to one payment record。*

Aggregate query 回傳 `booking_count = 1` 與 `payment_count = 1`，證明 rejected duplicate attempt 並未留下額外 booking 或 payment records。

![No residual booking or payment](https://iili.io/CC5CfVa.md.png)

*Figure 7.7. Rejected duplicate booking 後的 transaction integrity。*
