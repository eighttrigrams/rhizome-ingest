# Rhizome Ingest

An ingest starts with a folder of photos of individual pages.

Use this prompt

```
Read every page of /Users/daniel/Downloads/Ingest/The\ Prize/ and     
  name it according to its page number. i.e. p.1.jpg for page one        
  (preserve file ending as is). 
```  

I have tested this for roughly 30 pages.

Use `./transcribe-all.sh` to transcribe the files. Set the working dir
in `transcribe.conf`. It uses `tesseract` OCR (installed via `homebrew`).
It creates sidecar files for each of the files.
