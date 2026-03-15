#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = [
#   "lancedb>=0.24.0",
#   "pyarrow>=16.0.0",
#   "numpy>=1.26.0",
#   "dateparser>=1.2.0",
# ]
# ///

import json
import os
import sys
import traceback
from datetime import datetime, timedelta

import dateparser
import lancedb
import numpy as np
import pyarrow as pa


STATE = {"dbs": {}}


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def handle(request):
    options = request.get("options", {})
    db, memory_table_name, buffer_table_name = open_db(options)
    op = request["op"]

    if op == "ensure_ready":
        ensure_buffer_table(db, buffer_table_name)
        maybe_create_memory_table(db, memory_table_name, options)
        return {"ok": True}
    if op == "put":
        return put_memory(db, memory_table_name, request["unit"], options)
    if op == "get":
        return get_memory(db, memory_table_name, request["namespace"], request["entry_id"])
    if op == "delete":
        delete_memory(db, memory_table_name, request["namespace"], request["entry_id"])
        return {"ok": True}
    if op == "list":
        return list_memories(db, memory_table_name, request["namespace"])
    if op == "search":
        return search_memories(db, memory_table_name, request["namespace"], request["plan"])
    if op == "load_buffer":
        return load_buffer(db, buffer_table_name, request["namespace"], request["session_id"])
    if op == "replace_buffer":
        replace_buffer(
            db,
            buffer_table_name,
            request["namespace"],
            request["session_id"],
            request["state"],
        )
        return {"ok": True}
    if op == "delete_buffer":
        delete_buffer(db, buffer_table_name, request["namespace"], request["session_id"])
        return {"ok": True}

    raise ValueError(f"unsupported op: {op}")


def open_db(options):
    path = options["path"]
    key = (path, options.get("memory_table", "memory_entries"), options.get("buffer_table", "session_buffers"))
    if key not in STATE["dbs"]:
        os.makedirs(path, exist_ok=True)
        STATE["dbs"][key] = (
            lancedb.connect(path),
            key[1],
            key[2],
        )
    return STATE["dbs"][key]


def ensure_buffer_table(db, table_name):
    if table_name in db.table_names():
        return db.open_table(table_name)

    schema = pa.schema(
        [
            pa.field("namespace", pa.string()),
            pa.field("session_id", pa.string()),
            pa.field("dialogues_json", pa.string()),
            pa.field("recent_entries_json", pa.string()),
            pa.field("processed_cursor", pa.int64()),
            pa.field("updated_at", pa.int64()),
        ]
    )
    return db.create_table(table_name, schema=schema)


def maybe_create_memory_table(db, table_name, options, seed_row=None):
    if table_name in db.table_names():
        table = db.open_table(table_name)
        ensure_fts_index(table)
        return table

    vector_dimensions = options.get("vector_dimensions")
    if seed_row is None and not vector_dimensions:
        return None

    if seed_row is not None:
        table = db.create_table(table_name, data=[normalize_memory_row(seed_row)])
        ensure_fts_index(table)
        return table

    schema = pa.schema(
        [
            pa.field("entry_id", pa.string()),
            pa.field("namespace", pa.string()),
            pa.field("lossless_restatement", pa.string()),
            pa.field("search_text", pa.string()),
            pa.field("original_text", pa.string()),
            pa.field("class", pa.string()),
            pa.field("kind", pa.string()),
            pa.field("tags", pa.list_(pa.string())),
            pa.field("source", pa.string()),
            pa.field("observed_at", pa.int64()),
            pa.field("expires_at", pa.int64()),
            pa.field("timestamp", pa.string()),
            pa.field("persons", pa.list_(pa.string())),
            pa.field("persons_text", pa.string()),
            pa.field("entities", pa.list_(pa.string())),
            pa.field("entities_text", pa.string()),
            pa.field("location", pa.string()),
            pa.field("topic", pa.string()),
            pa.field("keywords", pa.list_(pa.string())),
            pa.field("content_json", pa.string()),
            pa.field("metadata_json", pa.string()),
            pa.field("vector", pa.list_(pa.float32(), int(vector_dimensions))),
        ]
    )
    table = db.create_table(table_name, schema=schema)
    ensure_fts_index(table)
    return table


def ensure_fts_index(table):
    try:
        table.create_fts_index("search_text", use_tantivy=True, tokenizer_name="en_stem", replace=True)
    except Exception:
        pass


def memory_rows(db, table_name):
    if table_name not in db.table_names():
        return []
    return db.open_table(table_name).to_arrow().to_pylist()


def put_memory(db, table_name, unit, options):
    created = table_name not in db.table_names()
    table = maybe_create_memory_table(db, table_name, options, seed_row=unit)
    row = normalize_memory_row(unit)

    if not created and table.count_rows() > 0:
        try:
            table.delete(
                f"entry_id = '{escape_string(row['entry_id'])}' and namespace = '{escape_string(row['namespace'])}'"
            )
        except Exception:
            pass

    if not created:
        table.add([project_to_schema(table, row)])

    ensure_fts_index(table)
    return denormalize_memory_row(row)


def get_memory(db, table_name, namespace, entry_id):
    rows = [
        row
        for row in memory_rows(db, table_name)
        if row.get("namespace") == namespace and row.get("entry_id") == entry_id
    ]
    if not rows:
        return None
    return denormalize_memory_row(rows[0])


def delete_memory(db, table_name, namespace, entry_id):
    if table_name not in db.table_names():
        return
    table = db.open_table(table_name)
    table.delete(
        f"entry_id = '{escape_string(entry_id)}' and namespace = '{escape_string(namespace)}'"
    )


def list_memories(db, table_name, namespace):
    rows = [row for row in memory_rows(db, table_name) if row.get("namespace") == namespace]
    rows.sort(key=lambda row: row.get("observed_at") or 0, reverse=True)
    return [denormalize_memory_row(row) for row in rows]


def search_memories(db, table_name, namespace, plan):
    rows = [row for row in memory_rows(db, table_name) if row.get("namespace") == namespace]
    if not rows:
        return []

    limit = int(plan.get("fetch_limit", plan.get("limit", 10)))
    semantic_rows = semantic_search(db, table_name, namespace, plan, limit)
    lexical_rows = lexical_search(db, table_name, namespace, plan, limit)
    structured_rows = structured_search(db, table_name, namespace, plan, limit)

    merged = {}

    for channel, channel_rows in [
        ("structured", structured_rows),
        ("semantic", semantic_rows),
        ("keyword", lexical_rows),
    ]:
        for rank, row in enumerate(channel_rows, start=1):
            entry_id = row["entry_id"]
            candidate = merged.setdefault(
                entry_id,
                {
                    "unit": denormalize_memory_row(row),
                    "lexical_score": 0.0,
                    "semantic_score": 0.0,
                    "symbolic_score": 0.0,
                    "recency_score": recency_score(row),
                    "channels": [],
                    "lexical_rank": None,
                    "semantic_rank": None,
                    "structured_rank": None,
                },
            )
            if channel not in candidate["channels"]:
                candidate["channels"].append(channel)
            if channel == "semantic":
                candidate["semantic_rank"] = min_or_value(candidate["semantic_rank"], rank)
                candidate["semantic_score"] = max(candidate["semantic_score"], float(row.get("_semantic_score", rank_score(rank))))
            elif channel == "keyword":
                candidate["lexical_rank"] = min_or_value(candidate["lexical_rank"], rank)
                candidate["lexical_score"] = max(candidate["lexical_score"], float(row.get("_lexical_score", rank_score(rank))))
            else:
                candidate["structured_rank"] = min_or_value(candidate["structured_rank"], rank)
                candidate["symbolic_score"] = max(candidate["symbolic_score"], float(row.get("_symbolic_score", rank_score(rank))))

    candidates = list(merged.values())
    candidates.sort(key=candidate_sort_key)
    return candidates[: int(plan.get("limit", 10))]


def semantic_search(db, table_name, namespace, plan, limit):
    if not plan.get("query_embedding"):
        return []

    if table_name not in db.table_names():
        return []

    table = db.open_table(table_name)

    try:
        search = table.search(plan["query_embedding"])
        where = build_filter(namespace, plan)
        if where:
            search = search.where(where, prefilter=True)
        results = search.limit(limit).to_list()
        normalized = []
        for rank, row in enumerate(results, start=1):
            row = dict(row)
            distance = row.get("_distance")
            score = max(0.0, 1.0 - float(distance)) if distance is not None else rank_score(rank)
            row["_semantic_score"] = score
            normalized.append(row)
        return normalized
    except Exception:
        return []


def lexical_search(db, table_name, namespace, plan, limit):
    keywords = plan.get("keywords") or []
    query = " ".join(keywords).strip()
    if not query or table_name not in db.table_names():
        return []

    table = db.open_table(table_name)
    try:
        search = table.search(query)
        where = build_filter(namespace, plan)
        if where:
            search = search.where(where, prefilter=True)
        results = search.limit(limit).to_list()
        normalized = []
        for rank, row in enumerate(results, start=1):
            row = dict(row)
            score = row.get("_score")
            row["_lexical_score"] = float(score) if score is not None else rank_score(rank)
            normalized.append(row)
        return normalized
    except Exception:
        return []


def structured_search(db, table_name, namespace, plan, limit):
    filter_expression = build_structured_filter(namespace, plan)
    if not filter_expression or table_name not in db.table_names():
        return []

    table = db.open_table(table_name)

    try:
        rows = table.to_arrow(filter=filter_expression).to_pylist()
    except Exception:
        return []

    normalized = []
    for rank, row in enumerate(rows[:limit], start=1):
        row = dict(row)
        score = 0
        if plan.get("persons"):
            score += 1
        if plan.get("entities"):
            score += 1
        if plan.get("location"):
            score += 1
        if plan.get("time_expression"):
            score += 1
        row["_symbolic_score"] = score / 4.0 if score else rank_score(rank)
        normalized.append(row)
    return normalized[:limit]


def load_buffer(db, table_name, namespace, session_id):
    rows = ensure_buffer_table(db, table_name).to_arrow().to_pylist()
    for row in rows:
        if row.get("namespace") == namespace and row.get("session_id") == session_id:
            return {
                "dialogues": json.loads(row.get("dialogues_json") or "[]"),
                "recent_entries": json.loads(row.get("recent_entries_json") or "[]"),
                "processed_cursor": int(row.get("processed_cursor") or 0),
            }
    return {"dialogues": [], "recent_entries": [], "processed_cursor": 0}


def replace_buffer(db, table_name, namespace, session_id, state):
    table = ensure_buffer_table(db, table_name)
    table.delete(
        f"namespace = '{escape_string(namespace)}' and session_id = '{escape_string(session_id)}'"
    )
    table.add(
        [
            project_to_schema(table, {
                "namespace": namespace,
                "session_id": session_id,
                "dialogues_json": json.dumps(state.get("dialogues") or []),
                "recent_entries_json": json.dumps(state.get("recent_entries") or []),
                "processed_cursor": int(state.get("processed_cursor") or 0),
                "updated_at": int(datetime.utcnow().timestamp() * 1000),
            })
        ]
    )


def delete_buffer(db, table_name, namespace, session_id):
    table = ensure_buffer_table(db, table_name)
    table.delete(
        f"namespace = '{escape_string(namespace)}' and session_id = '{escape_string(session_id)}'"
    )


def normalize_memory_row(unit):
    search_text = " ".join(
        [
            unit.get("lossless_restatement") or "",
            " ".join(unit.get("keywords") or []),
            " ".join(unit.get("persons") or []),
            " ".join(unit.get("entities") or []),
            unit.get("location") or "",
            unit.get("topic") or "",
        ]
    ).strip()

    return {
        "entry_id": unit["entry_id"],
        "namespace": unit["namespace"],
        "lossless_restatement": unit["lossless_restatement"],
        "search_text": search_text,
        "original_text": unit.get("original_text") or "",
        "class": unit.get("class") or "episodic",
        "kind": unit.get("kind") or "memory",
        "tags": [str(value) for value in unit.get("tags") or []],
        "source": unit.get("source") or "",
        "observed_at": int(unit.get("observed_at") or int(datetime.utcnow().timestamp() * 1000)),
        "expires_at": int(unit["expires_at"]) if unit.get("expires_at") is not None else None,
        "timestamp": unit.get("timestamp") or "",
        "persons": [str(value) for value in unit.get("persons") or []],
        "persons_text": "|" + "|".join(str(value) for value in unit.get("persons") or []) + "|",
        "entities": [str(value) for value in unit.get("entities") or []],
        "entities_text": "|" + "|".join(str(value) for value in unit.get("entities") or []) + "|",
        "location": unit.get("location") or "",
        "topic": unit.get("topic") or "",
        "keywords": [str(value) for value in unit.get("keywords") or []],
        "content_json": json.dumps(unit.get("content") or {}),
        "metadata_json": json.dumps(unit.get("metadata") or {}),
        "vector": [float(value) for value in unit.get("vector") or []],
    }


def denormalize_memory_row(row):
    return {
        "entry_id": row.get("entry_id"),
        "namespace": row.get("namespace"),
        "lossless_restatement": row.get("lossless_restatement") or "",
        "original_text": row.get("original_text") or None,
        "class": row.get("class") or "episodic",
        "kind": row.get("kind") or "memory",
        "tags": list(row.get("tags") or []),
        "source": row.get("source") or None,
        "observed_at": row.get("observed_at"),
        "expires_at": row.get("expires_at"),
        "timestamp": row.get("timestamp") or None,
        "persons": list(row.get("persons") or []),
        "entities": list(row.get("entities") or []),
        "location": row.get("location") or None,
        "topic": row.get("topic") or None,
        "keywords": list(row.get("keywords") or []),
        "content": json.loads(row.get("content_json") or "{}"),
        "metadata": json.loads(row.get("metadata_json") or "{}"),
    }


def parse_time_range(time_expression):
    if not time_expression:
        return None
    try:
        parsed_date = dateparser.parse(time_expression, settings={"PREFER_DATES_FROM": "past"})
    except Exception:
        return None
    if not parsed_date:
        return None
    start = parsed_date.replace(hour=0, minute=0, second=0, microsecond=0)
    end = parsed_date.replace(hour=23, minute=59, second=59, microsecond=0)
    if "week" in time_expression.lower():
        start = start - timedelta(days=7)
        end = end + timedelta(days=7)
    return (start.isoformat(), end.isoformat())


def timestamp_in_range(timestamp, timestamp_range):
    if not timestamp:
        return False
    return timestamp_range[0] <= timestamp <= timestamp_range[1]


def recency_score(row):
    observed_at = row.get("observed_at") or 0
    age_ms = max(int(datetime.utcnow().timestamp() * 1000) - int(observed_at), 1)
    return 1.0 / (1.0 + age_ms / 86_400_000)


def rank_score(rank):
    return 1.0 / (1.0 + max(rank - 1, 0))


def project_to_schema(table, row):
    field_names = set(table.schema.names)
    return {key: value for key, value in row.items() if key in field_names}


def build_filter(namespace, plan):
    clauses = [f"namespace = '{escape_string(namespace)}'"]
    clauses.extend(structured_filter_clauses(plan))
    return " AND ".join(clauses)


def build_structured_filter(namespace, plan):
    clauses = structured_filter_clauses(plan)
    if not clauses:
        return None
    return " AND ".join([f"namespace = '{escape_string(namespace)}'"] + clauses)


def structured_filter_clauses(plan):
    clauses = []

    for person in plan.get("persons") or []:
        clauses.append(f"persons_text LIKE '%|{escape_like(person)}|%'")

    for entity in plan.get("entities") or []:
        clauses.append(f"entities_text LIKE '%|{escape_like(entity)}|%'")

    location = plan.get("location")
    if location:
        clauses.append(f"location LIKE '%{escape_like(location)}%'")

    timestamp_range = parse_time_range(plan.get("time_expression"))
    if timestamp_range:
        clauses.append(
            f"timestamp >= '{escape_string(timestamp_range[0])}' AND timestamp <= '{escape_string(timestamp_range[1])}'"
        )

    return clauses


def candidate_sort_key(candidate):
    priority = 3
    if "structured" in candidate["channels"]:
        priority = 0
    elif "semantic" in candidate["channels"]:
        priority = 1
    elif "keyword" in candidate["channels"]:
        priority = 2

    return (
        priority,
        candidate["structured_rank"] or sys.maxsize,
        candidate["semantic_rank"] or sys.maxsize,
        candidate["lexical_rank"] or sys.maxsize,
        -(candidate["symbolic_score"] + candidate["semantic_score"] + candidate["lexical_score"]),
        -candidate["recency_score"],
    )


def min_or_value(existing, value):
    if existing is None:
        return value
    return min(existing, value)


def escape_string(value):
    return str(value).replace("\\", "\\\\").replace("'", "\\'")


def escape_like(value):
    return escape_string(value).replace("%", "\\%").replace("_", "\\_")


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        request = json.loads(line)
        result = handle(request)
        send({"id": request["id"], "status": "ok", "result": result})
    except Exception as exc:
        send(
            {
                "id": request.get("id") if "request" in locals() and isinstance(request, dict) else None,
                "status": "error",
                "error": {
                    "message": str(exc),
                    "traceback": traceback.format_exc(limit=5),
                },
            }
        )
