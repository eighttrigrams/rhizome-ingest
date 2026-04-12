# Rhizome Ingest

Uses Rhizomes new Rest API. A skill for that is present under `.claude/skill/ingest-clj.md`.

## Page numbering

An ingest starts with a folder of photos of individual pages, best 
taken with the `vflat` app.

Use this prompt

```
Read every page of /absolute/path/to/your/working/directory and     
  name it according to its page number. i.e. p.1.jpg for page one        
  (preserve file ending as is). 
```  

I have tested this for roughly 30 pages.

## Transcription

Use `./transcribe-all.sh` to transcribe the files. Set the working dir
in `transcribe.conf`. It uses `tesseract` OCR (installed via `homebrew`).
It creates sidecar files for each of the files.

## Ingest

You can ingest all pages inside a folder with the (non-idempotent) operation

```
./ingest-pages.sh
```

## Bookquotes

Extacts underlined pages.

```
./extract-bookquotes.sh # all pages
./extract-bookquotes.sh 10 # single page
./extract-bookquotes.sh 5 15 # range
```

Roman numerals work as well here.

## New vocabulary

Extracts new vocabulary.

```
./extract-vocabulary.sh
```

Supports the same range arguments as `extract-bookquotes.sh`.
