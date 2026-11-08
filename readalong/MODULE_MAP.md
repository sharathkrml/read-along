# Module map for the Read Along Python backend
#
# The monolithic `readalong.py` was split into the `readalong/` package below.
# Each module owns one domain and modules only import from their dependencies
# (relative imports). `readalong/__init__.py` re-exports the public API so the
# file layout stays decoupled from the import surface. A thin root-level
# `readalong.py` shim remains as the executable entry point for the native
# backend (`macapp/BackendService.swift` runs `readalong.py` directly).
#
# readalong/
#   __init__.py        public API re-exports
#   __main__.py        main(), CLI argument parsing, startup/shutdown
#   _config.py         paths, model ids, ports, error classes
#   text_model.py      norm_token/norm_text/tokenize, build_pages_model,
#                      build_model, rebase_position, group_at/group_boxes,
#                      annotate_blocks
#   aligner.py         Aligner (ASR-to-script fuzzy alignment)
#   vision.py          macOS Vision line boxes, reading_order, usable_lines
#   mapping.py         clean_ocr, map_lines, _word_start_spans, _stacked_run
#   segment.py         _ink_mask, _char_width, segment_line, _boxes, _text_band
#   ocr.py             LFM3 OCR, run_ocr_many/run_ocr, _looks_printed
#   pdf.py             pdf_lines, pdf_pages, image_pages, process_source
#   cache.py           save_cache, load_cache, clear_pages, attach_word_boxes
#   speech.py          fermion_cmd, ASR, tail, list_mics
#   models.py          Models (speech/OCR downloads) + model-dir detection
#   library.py         DocumentStore (persistent document library)
#   app.py             App (backend orchestration + HTTP state)
#   export.py          export_image (page proof JPEG)
#   web.py             Handler (HTTP API) + APP singleton
#
# Root shim: readalong.py  ->  from readalong.__main__ import main; run main()
