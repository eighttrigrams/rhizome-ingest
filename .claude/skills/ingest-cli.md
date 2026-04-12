---
name: rhizome-ingest-cli
description: CLI tool for ingesting items into Rhizome via its REST API
triggers:
  - ingest
  - add item to rhizome
  - rhizome cli
  - add to context
---

# Rhizome Ingest CLI

`ingest.sh` is a bash CLI that talks to Rhizome's local REST API (`http://127.0.0.1:3006/rest/`).

## Prerequisites

- Rhizome must be running locally (default port 3006)
- `curl` and `python3` available on PATH

## Commands

The `--port` flag is mandatory and must come first.

### List contexts
```bash
./ingest.sh --port 3006 contexts
./ingest.sh --port 3006 contexts --search "Books"
```

### Create a context
```bash
./ingest.sh --port 3006 add-context "My New Context"
```

### Add an item linked to contexts
```bash
./ingest.sh --port 3006 add-item "Article title or URL" --contexts 42,17
```
The `--contexts` flag takes a comma-separated list of context IDs. At least one is required.
URLs (YouTube, GitHub, Substack, etc.) are auto-detected and enriched by rhizome's insertion pipeline.

### Get an item
```bash
./ingest.sh --port 3006 get-item 123
```

## REST API Endpoints (behind the scenes)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/rest/contexts` | List contexts (optional `?q=` search) |
| POST | `/rest/contexts` | Create context (`{"title": "..."}`) |
| POST | `/rest/items` | Create item (`{"title": "...", "context-ids": [1,2]}`) |
| GET | `/rest/items/:id` | Get item by ID |

## Batch page ingestion

`ingest-pages.sh` ingests all `p.*.md` files from a directory into rhizome, linking each page to a book context and a pages context. Configuration is in `ingest.conf` (copy from `ingest.conf.template`):

```
PORT=3006
BOOK_ID=<context-id-for-the-book>
PAGES_ID=<context-id-for-pages>
DIR="/path/to/pages"
```

Each page becomes an item with title `p.<N>` and the file content as description.

```bash
./ingest-pages.sh
```

The POST `/rest/items` endpoint also accepts an optional `description` field for setting item body text.

## Typical workflow

1. `./ingest.sh --port 3006 contexts --search "keyword"` to find the right context ID
2. `./ingest.sh --port 3006 add-item "title or URL" --contexts <id>` to ingest
3. For batch page ingestion: fill in `ingest.conf` and run `./ingest-pages.sh`
