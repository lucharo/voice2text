# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright"]
# ///
"""Check keyboard focus in a built docs preview: uv run utils/docs_bench_keyboard.py URL."""
import argparse

from playwright.sync_api import sync_playwright

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("url", help="URL of the served documentation site")
parser.add_argument("--browser", help="Optional Chromium executable")
args = parser.parse_args()

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=args.browser, headless=True)
    try:
        page = browser.new_page()
        page.goto(args.url.rstrip("/") + "/benchmarks/", wait_until="networkidle")
        page.wait_for_selector('[data-v2t-bench][data-ready="true"]')
        category = page.get_by_role("button", name="Cleanup fidelity", exact=True)
        category.focus()
        page.keyboard.press("Enter")
        assert category.evaluate("el => el === document.activeElement"), "Category lost focus"
        selector = page.get_by_label("Dataset or measurement")
        selector.focus()
        choices = selector.locator("option").evaluate_all("items => items.map(x => x.value)")
        assert len(choices) >= 3, "Need several datasets to exercise continued selection"
        for value in choices[1:3]:
            selector.select_option(value)
            assert selector.evaluate("el => el === document.activeElement"), "Dataset lost focus"
            assert page.locator(".bench-value").count() > 0, "Chart did not render"
        page.keyboard.press("Tab")
        assert page.get_by_text("Recorded measurements", exact=True).evaluate(
            "el => el === document.activeElement"
        ), "Tab did not continue to the measurement details"
        print("PASS: category activation, repeated dataset changes and Tab retain keyboard navigation")
    finally:
        browser.close()
