"""Evidence-preserving PDF figure inventory and correctable region crops.

Detection is deliberately labelled heuristic. Every page remains accessible,
including pages without detected captions. Cropped PDFs preserve original vector
and raster content; PNGs are viewing previews, not replacement scientific data.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import statistics


_CAPTION = re.compile(r"^\s*(?P<kind>fig(?:ure)?s?\.?|table|scheme|chart|图|表)\s*[:：.]?\s*(?P<number>S?\s*\d+[A-Za-z]?|[IVX]+)(?=$|[\s.:：、(（])", re.I)
_REFERENCE_SENTENCE = re.compile(r"^\s*(shows?|demonstrates?|indicates?|illustrates?|is\b|was\b|has\b|can\b|compares?|presents?)", re.I)


def _rect_values(rect):
    return [round(float(value), 4) for value in rect]


def _overlap_x(first, second):
    return max(0, min(first.x1, second.x1) - max(first.x0, second.x0))


def _area_overlap(first, second):
    intersection = first & second
    return 0 if intersection.is_empty else intersection.get_area() / max(1, min(first.get_area(), second.get_area()))


def _union(rectangles, fitz):
    result = fitz.Rect(rectangles[0])
    for rectangle in rectangles[1:]:
        result |= rectangle
    return result


def _text_blocks(page, fitz):
    blocks = []
    for index, block in enumerate(page.get_text("dict", flags=fitz.TEXTFLAGS_DICT & ~fitz.TEXT_PRESERVE_IMAGES)["blocks"]):
        if block.get("type") != 0:
            continue
        lines = []
        sizes = []
        for line in block.get("lines", []):
            text = "".join(span["text"] for span in line.get("spans", []))
            if not text.strip():
                continue
            sizes.extend(span["size"] for span in line.get("spans", []) if span["text"].strip())
            lines.append({"text": text, "rect": fitz.Rect(line["bbox"])})
        if lines:
            blocks.append({"index": index, "rect": fitz.Rect(block["bbox"]), "lines": lines,
                           "text": "\n".join(line["text"] for line in lines),
                           "font_size": sum(sizes) / len(sizes) if sizes else 10})
    return sorted(blocks, key=lambda item: (round(item["rect"].y0 / 3), item["rect"].x0))


def _captions(blocks, fitz):
    captions = []
    standalone_sizes = []
    for block in blocks:
        first = block["lines"][0]["text"]
        match = _CAPTION.match(first)
        if match and not first[match.end():].strip(" .:："):
            standalone_sizes.append(block["font_size"])
    caption_font = statistics.median(standalone_sizes) if standalone_sizes else None
    claimed_blocks = set()
    for block in blocks:
        if block["index"] in claimed_blocks:
            continue
        # Captions begin a text block. Later lines often contain cross-references
        # such as "Fig. 6", which must not become extra figures.
        for position, line in enumerate(block["lines"][:1]):
            match = _CAPTION.match(line["text"])
            if not match:
                continue
            # A prose reference at the beginning of a paragraph is not a caption.
            suffix = line["text"][match.end():]
            if _REFERENCE_SENTENCE.match(suffix):
                continue
            if suffix.startswith(("(", "（")):
                continue
            if caption_font and suffix.strip(" .:：") and block["font_size"] > caption_font * 1.12:
                continue
            raw_kind = match.group("kind").lower().rstrip(".")
            kind = "table" if raw_kind in ("table", "表") else "scheme" if raw_kind == "scheme" else "figure"
            label = ("Table" if kind == "table" else "Scheme" if kind == "scheme" else "Figure") + " " + re.sub(r"\s+", "", match.group("number"))
            lines = []
            for following in block["lines"][position:]:
                lines.append(following)
            rect = _union([item["rect"] for item in lines], fitz)
            text = "\n".join(item["text"] for item in lines)
            used_blocks = {block["index"]}
            # Continuation blocks must sit immediately below with matching font
            # and column alignment. Stop at whitespace/body font/caption changes.
            changed = True
            while changed:
                changed = False
                for next_block in blocks:
                    if next_block["index"] in used_blocks or next_block["index"] in claimed_blocks:
                        continue
                    gap = next_block["rect"].y0 - rect.y1
                    # Subscripts/superscripts and reaction symbols may be split
                    # into small, overlapping blocks with different fonts.
                    size_match = block["font_size"] * 0.45 <= next_block["font_size"] <= block["font_size"] * 1.08
                    aligned = rect.x0 - 12 <= next_block["rect"].x0 <= rect.x1
                    width_match = next_block["rect"].x1 <= rect.x1 + max(24, rect.width * 0.2)
                    below_start = next_block["rect"].y0 >= block["rect"].y0
                    if -block["font_size"] * 1.8 <= gap <= max(6, block["font_size"] * 1.4) and below_start and size_match and aligned and width_match:
                        text += "\n" + next_block["text"]
                        rect |= next_block["rect"]
                        used_blocks.add(next_block["index"])
                        changed = True
                        break
            claimed_blocks.update(used_blocks)
            captions.append({"kind": kind, "label": label, "caption": text,
                             "caption_rect": rect, "blocks": used_blocks})
    return captions


def _visual_regions(page, fitz):
    regions = []
    for image in page.get_image_info(xrefs=True):
        rect = fitz.Rect(image["bbox"]) & page.rect
        if not rect.is_empty:
            regions.append({"rect": rect, "type": "embedded_image", "xref": image.get("xref"),
                            "original_width": image.get("width"), "original_height": image.get("height")})
    warnings = []
    try:
        drawings = page.get_drawings()
        for rect in page.cluster_drawings(drawings=drawings, x_tolerance=14, y_tolerance=14):
            rect = fitz.Rect(rect) & page.rect
            if rect.width >= 45 and rect.height >= 30 and rect.get_area() < page.rect.get_area() * 0.95:
                regions.append({"rect": rect, "type": "vector_region"})
    except Exception as error:
        warnings.append(f"Vector-region detection failed on page {page.number + 1}: {type(error).__name__}")
    try:
        for table in page.find_tables().tables:
            regions.append({"rect": fitz.Rect(table.bbox), "type": "table_region",
                            "rows": table.row_count, "columns": table.col_count,
                            "cells": table.extract(), "header_names": table.header.names,
                            "header_external": table.header.external,
                            "table_cells_source": "pymupdf_table_extraction"})
    except Exception as error:
        warnings.append(f"Table detection failed on page {page.number + 1}: {type(error).__name__}")
    return regions, warnings


def _caption_region(caption, visuals, blocks, page_rect, fitz):
    cap = caption["caption_rect"]
    column = fitz.Rect(page_rect)
    if cap.width < page_rect.width * 0.6:
        midpoint = page_rect.x0 + page_rect.width / 2
        if (cap.x0 + cap.x1) / 2 < midpoint:
            column.x1 = midpoint - 4
        else:
            column.x0 = midpoint + 4
    same_column = [visual for visual in visuals if _overlap_x(visual["rect"], cap) > min(visual["rect"].width, cap.width) * 0.25]
    if caption["kind"] == "table":
        candidates = [visual for visual in same_column if visual["type"] == "table_region"]
        candidates.sort(key=lambda visual: min(abs(visual["rect"].y0 - cap.y1), abs(visual["rect"].y1 - cap.y0)))
    else:
        candidates = [visual for visual in same_column if visual["rect"].y1 <= cap.y0 + 8
                      and cap.y0 - visual["rect"].y1 < page_rect.height * 0.55]
        candidates.sort(key=lambda visual: max(0, cap.y0 - visual["rect"].y1))
    if candidates:
        anchor = candidates[0]
        visual_rect = fitz.Rect(anchor["rect"])
        selected = [anchor]
        # Include neighboring panels at the same vertical level, but not another
        # unrelated figure separated by a caption or substantial body text.
        for visual in same_column:
            if visual is anchor:
                continue
            rect = visual["rect"]
            vertical_overlap = min(rect.y1, visual_rect.y1) - max(rect.y0, visual_rect.y0)
            if vertical_overlap > min(rect.height, visual_rect.height) * 0.35 and rect.y1 <= cap.y0 + 8:
                visual_rect |= rect
                selected.append(visual)
        rect = _union([visual_rect, cap], fitz)
        rect += (-8, -8, 8, 5)
        # Include tick labels and panel annotations lying just outside vector bounds.
        for block in blocks:
            candidate = block["rect"]
            if candidate.y1 <= cap.y0 + 2 and candidate.y0 >= visual_rect.y0 - 12 and candidate.y1 >= visual_rect.y0:
                if _area_overlap(candidate, rect) > 0.45:
                    rect |= candidate
        return rect & page_rect, 0.88 if anchor["type"] in ("embedded_image", "table_region") else 0.72, selected, "caption_and_visual_geometry"
    # Text-only or unusual layout: keep a generously bounded region and label it
    # low-confidence. The user can inspect the complete page or provide a bbox.
    prior = [block["rect"].y1 for block in blocks if block["index"] not in caption["blocks"]
             and block["rect"].y1 <= cap.y0 - 10 and _overlap_x(block["rect"], cap) > cap.width * 0.25]
    top = max(prior, default=max(0, cap.y0 - page_rect.height * 0.35))
    if caption["kind"] == "table":
        following = [block["rect"].y0 for block in blocks if block["index"] not in caption["blocks"]
                     and block["rect"].y0 > cap.y1 + 30 and _overlap_x(block["rect"], cap) > cap.width * 0.25]
        rect = fitz.Rect(max(column.x0, cap.x0 - 8), cap.y0 - 4,
                         min(column.x1, cap.x1 + 8), min(following, default=page_rect.y1 - 20))
    else:
        rect = fitz.Rect(max(column.x0, cap.x0 - 12), max(0, top + 2),
                         min(column.x1, cap.x1 + 12), cap.y1 + 5)
    rect |= cap
    return rect & page_rect, 0.35, [], "caption_only_region_needs_review"


def _item_id(document_id, page, label):
    slug = re.sub(r"[^A-Za-z0-9_-]+", "-", label).strip("-").lower()
    return f"{document_id}-p{page}-{slug or hashlib.sha256(label.encode()).hexdigest()[:10]}"


def _apply_overrides(items, overrides, document_id, page_rects, fitz):
    for override in overrides or []:
        if override.get("document_id", "main") != document_id:
            continue
        number = override.get("page")
        if type(number) is not int or number not in page_rects:
            raise ValueError("Manual figure bbox requires a valid one-based page number.")
        label = str(override.get("label", "Manual figure"))
        matching = [item for item in items if (override.get("id") and item["id"] == override["id"])
                    or (not override.get("id") and item["page"] == number and item["label"].casefold() == label.casefold())]
        if override.get("id") and not matching:
            raise ValueError(f"Manual figure id does not exist: {override['id']}")
        if override.get("exclude"):
            for item in matching:
                item["excluded_by_user"] = True
                item["include_in_guide"] = False
            continue
        values = override.get("rect", override.get("bbox"))
        if not isinstance(values, list) or len(values) != 4 or any(type(value) not in (int, float) for value in values):
            raise ValueError("Manual figure rect must contain four PDF point coordinates.")
        rect = fitz.Rect(values)
        page_rect = page_rects[number]
        if rect.is_empty or rect.is_infinite or not page_rect.contains(rect):
            raise ValueError("Manual figure rect must be nonempty and inside its unrotated PDF page.")
        item = matching[0] if matching else {"id": _item_id(document_id, number, label), "document_id": document_id,
                                           "page": number, "label": label, "kind": override.get("kind", "figure")}
        item.update(rect=_rect_values(rect), caption=str(override.get("caption", item.get("caption", ""))),
                    confidence=1.0, bbox_confidence=1.0, source="manual", detection_reason="user_supplied_bbox",
                    include_in_guide=True, excluded_by_user=False)
        if not matching:
            items.append(item)


def extract_figure_inventory(pdf_path, output_dir, document_id="main", overrides=None, page_previews=None):
    import pymupdf as fitz

    pdf_path = Path(pdf_path).expanduser().resolve(strict=True)
    directory = Path(output_dir).expanduser().resolve()
    directory.mkdir(parents=True, exist_ok=True)
    if not re.fullmatch(r"[A-Za-z0-9_-]+", document_id):
        raise ValueError("document_id must use letters, digits, underscores or hyphens.")
    if overrides is not None and not isinstance(overrides, list):
        raise ValueError("figure_boxes must be an array of manual bbox records.")
    items = []
    warnings = []
    previews = []
    page_rects = {}
    rotations = {}
    supplied_previews = {item["page"]: item for item in (page_previews or [])}
    with fitz.open(pdf_path) as document:
        if document.needs_pass:
            raise ValueError("Encrypted PDF must be unlocked before figure extraction.")
        for index, page in enumerate(document):
            number = index + 1
            rotations[number] = page.rotation
            page.set_rotation(0)
            page_rects[number] = fitz.Rect(page.rect)
            blocks = _text_blocks(page, fitz)
            captions = _captions(blocks, fitz)
            visuals, page_warnings = _visual_regions(page, fitz)
            warnings.extend(page_warnings)
            assigned = set()
            for caption in captions:
                rect, confidence, chosen, reason = _caption_region(caption, visuals, blocks, page.rect, fitz)
                assigned.update(id(visual) for visual in chosen)
                items.append({"id": _item_id(document_id, number, caption["label"]), "document_id": document_id,
                              "page": number, "label": caption["label"], "kind": caption["kind"],
                              "caption": caption["caption"], "caption_rect": _rect_values(caption["caption_rect"]),
                              "rect": _rect_values(rect), "confidence": confidence, "bbox_confidence": confidence,
                              "source": "heuristic", "detection_reason": reason, "include_in_guide": True})
                tables = [visual for visual in chosen if visual["type"] == "table_region"]
                if caption["kind"] == "table" and tables:
                    for key in ("cells", "header_names", "header_external", "rows", "columns", "table_cells_source"):
                        items[-1][key] = tables[0][key]
            for visual_index, visual in enumerate(visuals, 1):
                if id(visual) in assigned or any(item["page"] == number and _area_overlap(fitz.Rect(item["rect"]), visual["rect"]) > 0.8 for item in items):
                    continue
                rect = visual["rect"]
                margin_image = visual["type"] == "embedded_image" and rect.width < 28 and (rect.x1 < page.rect.width * 0.07 or rect.x0 > page.rect.width * 0.93)
                label = ("Unlabelled table" if visual["type"] == "table_region" else "Unclassified visual") + f" {visual_index}"
                items.append({"id": _item_id(document_id, number, label), "document_id": document_id,
                              "page": number, "label": label, "kind": visual["type"], "caption": "",
                              "rect": _rect_values((rect + (-5, -5, 5, 5)) & page.rect), "confidence": 0.5,
                              "bbox_confidence": 0.5, "source": "heuristic", "detection_reason": "visual_without_caption",
                              "include_in_guide": not margin_image, "possible_margin_decoration": margin_image,
                              "original_image_size": [visual.get("original_width"), visual.get("original_height")]
                              if visual["type"] == "embedded_image" else None})
                if visual["type"] == "table_region":
                    for key in ("cells", "header_names", "header_external", "rows", "columns", "table_cells_source"):
                        items[-1][key] = visual[key]
            existing = supplied_previews.get(number)
            if existing and Path(existing.get("path", existing.get("image_path", ""))).is_file():
                previews.append({**existing, "document_id": document_id})
            else:
                preview = page.get_pixmap(matrix=fitz.Matrix(1.5, 1.5), alpha=False)
                path = directory / f"{document_id}-page-{number:04d}.png"
                preview.save(path)
                previews.append({"document_id": document_id, "page": number, "path": str(path),
                                 "width": preview.width, "height": preview.height})
        _apply_overrides(items, overrides, document_id, page_rects, fitz)
        seen = {}
        for item in items:
            count = seen.get(item["id"], 0)
            seen[item["id"]] = count + 1
            if count:
                item["id"] += f"-{count + 1}"
            page = document[item["page"] - 1]
            page.set_rotation(0)
            rect = fitz.Rect(item["rect"])
            image_path = directory / (item["id"] + ".png")
            preview = page.get_pixmap(matrix=fitz.Matrix(2, 2), clip=rect, alpha=False)
            preview.save(image_path)
            pdf_crop = directory / (item["id"] + ".pdf")
            with fitz.open() as crop:
                target = crop.new_page(width=rect.width, height=rect.height)
                target.show_pdf_page(target.rect, document, item["page"] - 1, clip=rect)
                crop.save(pdf_crop)
            item.update(image_path=str(image_path), path=str(image_path), pdf_path=str(pdf_crop),
                        width=preview.width, height=preview.height, coordinate_space="unrotated_pdf_points",
                        page_width=page.rect.width, page_height=page.rect.height,
                        original_page_rotation=rotations[item["page"]])
    warnings.append("Figure/table detection is heuristic and not exhaustive. Inspect every original page; captions, panels or borderless tables may be missed or misbounded.")
    report = {"document_id": document_id, "source_path": str(pdf_path),
              "source_sha256": hashlib.sha256(pdf_path.read_bytes()).hexdigest(), "items": items,
              "page_previews": previews, "page_count": len(page_rects), "coverage": "heuristic_not_exhaustive",
              "coordinate_space": "unrotated_pdf_points", "warnings": warnings}
    (directory / "inventory.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return report
