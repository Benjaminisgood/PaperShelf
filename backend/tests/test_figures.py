import hashlib
from pathlib import Path
import tempfile
import unittest

import pymupdf as fitz

from papershelf_pipeline.figures import extract_figure_inventory


def make_fixture(path):
    with fitz.open() as document:
        page = document.new_page(width=500, height=700)
        page.insert_text((45, 35), "Synthetic figure extraction fixture", fontsize=13)
        page.draw_rect(fitz.Rect(60, 80, 245, 250), color=(0, 0, 0))
        page.draw_polyline([(70, 230), (100, 210), (140, 140), (190, 110), (230, 85)], color=(0, 0, 1))
        page.insert_text((72, 105), "Synthetic curve; no experimental data", fontsize=8)
        page.insert_text((50, 275), "Figure 1. A synthetic vector figure.", fontsize=9)
        page.insert_text((50, 287), "Caption continuation in a separate text block.", fontsize=9)
        page.insert_text((50, 330), "Figure 1 shows a curve in the preceding illustration.", fontsize=10)
        page.insert_text((50, 380), "Table S1. Synthetic conditions.", fontsize=9)
        for x in (50, 150, 250):
            page.draw_line((x, 395), (x, 485))
        for y in (395, 425, 455, 485):
            page.draw_line((50, y), (250, y))
        for row, cells in enumerate((("Case", "Temperature"), ("A", "300"), ("B", "400"))):
            for column, text in enumerate(cells):
                page.insert_text((60 + column * 100, 415 + row * 30), text, fontsize=10)
        page = document.new_page(width=500, height=700)
        page.insert_text((45, 35), "Second page with no labelled figure", fontsize=12)
        page.draw_rect(fitz.Rect(80, 100, 300, 250), color=(1, 0, 0), fill=(1, 0.9, 0.9))
        document.save(path)


class FigureInventoryTests(unittest.TestCase):
    def test_detect_captions_tables_and_keep_all_pages_and_original_pdf(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "fixture.pdf"
            make_fixture(source)
            before = hashlib.sha256(source.read_bytes()).hexdigest()
            report = extract_figure_inventory(source, root / "figures")
            self.assertEqual(report["coverage"], "heuristic_not_exhaustive")
            self.assertEqual(len(report["page_previews"]), 2)
            labelled = {item["label"]: item for item in report["items"] if item["kind"] in ("figure", "table")}
            self.assertEqual(set(labelled), {"Figure 1", "Table S1"})
            self.assertIn("Caption continuation", labelled["Figure 1"]["caption"])
            self.assertNotIn("preceding illustration", labelled["Figure 1"]["caption"])
            self.assertLess(labelled["Figure 1"]["rect"][1], 90)
            self.assertGreater(labelled["Table S1"]["rect"][3], 480)
            self.assertEqual(labelled["Table S1"]["cells"], [["Case", "Temperature"], ["A", "300"], ["B", "400"]])
            for item in report["items"]:
                self.assertTrue(Path(item["image_path"]).is_file())
                with fitz.open(item["pdf_path"]) as crop:
                    self.assertEqual(len(crop), 1)
                    self.assertAlmostEqual(crop[0].rect.width, item["rect"][2] - item["rect"][0], places=2)
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), before)

    def test_manual_bounds_override_heuristic_and_keep_original_names(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "fixture.pdf"
            make_fixture(source)
            report = extract_figure_inventory(source, root / "figures", "s1", [
                {"document_id": "s1", "page": 1, "label": "Figure 1", "rect": [45, 65, 260, 305]},
                {"document_id": "s1", "page": 2, "label": "补充图 2", "rect": [70, 90, 310, 260], "caption": "手动核对区域"}])
            manual = [item for item in report["items"] if item["source"] == "manual"]
            self.assertEqual(len(manual), 2)
            self.assertEqual(manual[0]["rect"], [45, 65, 260, 305])
            self.assertEqual(manual[1]["label"], "补充图 2")
            self.assertEqual(manual[1]["coordinate_space"], "unrotated_pdf_points")

    def test_invalid_override_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "fixture.pdf"
            make_fixture(source)
            with self.assertRaises(ValueError):
                extract_figure_inventory(source, root / "figures", overrides=[
                    {"page": 1, "label": "Figure 1", "rect": [-1, 0, 800, 400]}])

    def test_reuses_existing_page_previews(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "fixture.pdf"
            make_fixture(source)
            existing = root / "existing.png"
            with fitz.open(source) as document:
                document[0].get_pixmap().save(existing)
            report = extract_figure_inventory(source, root / "figures", page_previews=[{"page": 1, "path": str(existing)}])
            self.assertEqual(report["page_previews"][0]["path"], str(existing))
            self.assertFalse((root / "figures/main-page-0001.png").exists())

    def test_caption_cross_reference_and_split_math_are_not_truncated(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "split-caption.pdf"
            with fitz.open() as document:
                page = document.new_page(width=500, height=500)
                page.draw_rect(fitz.Rect(50, 50, 420, 170))
                page.insert_text((45, 190), "Figure 7\nA synthetic caption with a reaction below.\nFig. 6. This is a reference inside the same caption.", fontsize=9)
                page.insert_text((45, 233), "reaction E + S", fontsize=9)
                page.insert_text((120, 229), "kf", fontsize=6)
                page.insert_text((120, 238), "kr", fontsize=6)
                page.insert_text((136, 233), "ES. Initial conditions are [1, 2, 0].", fontsize=9)
                page.insert_text((45, 246), "All caption conditions are retained.", fontsize=9)
                document.save(source)
            report = extract_figure_inventory(source, root / "figures")
            captions = [item for item in report["items"] if item["kind"] == "figure"]
            self.assertEqual(len(captions), 1)
            self.assertIn("Fig. 6.", captions[0]["caption"])
            self.assertIn("kf", captions[0]["caption"])
            self.assertIn("kr", captions[0]["caption"])
            self.assertIn("All caption conditions", captions[0]["caption"])
            self.assertGreater(captions[0]["rect"][3], 246)


if __name__ == "__main__":
    unittest.main()
